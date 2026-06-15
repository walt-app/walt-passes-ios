import Foundation
import GRDB
import Testing

@testable import PassesStorage

/// Schema round-trip coverage for `GrdbDatabaseFactory`: a fresh file reaches the current
/// version with every table present, reopening is idempotent, an older file walks the
/// `Schema.migrations` ladder, and a newer-than-known file refuses to open. Runs on the
/// macOS host (Data Protection is a no-op off-device), so it exercises the DDL and
/// migration machinery without an iOS runtime.
@Suite("GrdbDatabaseFactory")
struct GrdbDatabaseFactoryTests {

    /// Creates a unique temp DB path and removes it (plus sidecars) after `body`.
    private func withTempDatabase<R>(_ body: (URL) throws -> R) throws -> R {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("walt_passes_test_\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        return try body(url)
    }

    @Test func freshDatabaseReachesCurrentVersion() throws {
        try withTempDatabase { url in
            let queue = try GrdbDatabaseFactory.open(at: url)
            let version = try queue.read { try GrdbDatabaseFactory.readVersion($0) }
            #expect(version == Schema.version)
        }
    }

    @Test func freshDatabaseCreatesEveryTable() throws {
        try withTempDatabase { url in
            let queue = try GrdbDatabaseFactory.open(at: url)
            let tables = [
                Schema.Tables.schemaMeta, Schema.Tables.passes, Schema.Tables.passImages,
                Schema.Tables.passLocales, Schema.Tables.documents,
                Schema.Tables.documentThumbnails, Schema.Tables.scannableCards,
            ]
            let present = try queue.read { db in
                try tables.filter { try db.tableExists($0) }
            }
            #expect(present == tables)
        }
    }

    @Test func passesIdentityIndexIsUnique() throws {
        try withTempDatabase { url in
            let queue = try GrdbDatabaseFactory.open(at: url)
            try queue.write { db in
                let insert = """
                    INSERT INTO passes
                        (type, serial_number, organization_name, description,
                         voided, signature_status_kind, pass_json,
                         created_at_epoch_ms, updated_at_epoch_ms)
                    VALUES ('generic', 'sn', 'org', 'desc', 0, 'unsigned', x'00', 0, 0)
                    """
                try db.execute(sql: insert)
                // Same (type, serial_number, organization_name) tuple must collide.
                #expect(throws: (any Error).self) {
                    try db.execute(sql: insert)
                }
            }
        }
    }

    @Test func reopeningIsIdempotent() throws {
        try withTempDatabase { url in
            _ = try GrdbDatabaseFactory.open(at: url)
            let reopened = try GrdbDatabaseFactory.open(at: url)
            let version = try reopened.read { try GrdbDatabaseFactory.readVersion($0) }
            #expect(version == Schema.version)
        }
    }

    @Test func v4ScannableCardsTableHasNoColorColumn() throws {
        try withTempDatabase { url in
            let queue = try GrdbDatabaseFactory.open(at: url)
            try queue.read { db in
                let columns = try db.columns(in: Schema.Tables.scannableCards).map(\.name)
                #expect(columns.contains("payload"))
                #expect(columns.contains("format"))
                #expect(columns.contains("label"))
                #expect(!columns.contains("color_argb"))
            }
        }
    }

    @Test func migratesV1DatabaseForwardToCurrent() throws {
        try withTempDatabase { url in
            // Stand up a synthetic v1 database: schema_meta + the v1 `passes` shape only,
            // stamped at version 1, then let the factory walk migrations to current.
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)
                    """)
                try db.execute(sql: """
                    CREATE TABLE passes (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        type TEXT NOT NULL, serial_number TEXT NOT NULL,
                        organization_name TEXT NOT NULL, description TEXT NOT NULL,
                        expiration_epoch_ms INTEGER, voided INTEGER NOT NULL DEFAULT 0,
                        signature_status_kind TEXT NOT NULL, pass_json BLOB NOT NULL,
                        created_at_epoch_ms INTEGER NOT NULL, updated_at_epoch_ms INTEGER NOT NULL
                    )
                    """)
                try GrdbDatabaseFactory.writeVersion(db, 1)
            }

            try GrdbDatabaseFactory.migrate(queue)

            let (version, hasDocuments, hasScannable, scannableColumns, passesColumns) = try queue.read { db in
                (
                    try GrdbDatabaseFactory.readVersion(db),
                    try db.tableExists(Schema.Tables.documents),
                    try db.tableExists(Schema.Tables.scannableCards),
                    try db.columns(in: Schema.Tables.scannableCards).map(\.name),
                    try db.columns(in: Schema.Tables.passes).map(\.name)
                )
            }
            #expect(version == Schema.version)
            // v1->v2 added documents; v2->v3 added scannable_cards.
            #expect(hasDocuments)
            #expect(hasScannable)
            // v3->v4 dropped color_argb.
            #expect(!scannableColumns.contains("color_argb"))
            // v4->v5 added user_label.
            #expect(passesColumns.contains("user_label"))
        }
    }

    /// The fresh `ddl` and the migration ladder must agree on the `passes` shape: both add
    /// `user_label`, or a fresh install and an upgraded install silently drift.
    @Test func freshDatabaseHasUserLabelColumn() throws {
        try withTempDatabase { url in
            let queue = try GrdbDatabaseFactory.open(at: url)
            let passesColumns = try queue.read { db in
                try db.columns(in: Schema.Tables.passes).map(\.name)
            }
            #expect(passesColumns.contains("user_label"))
        }
    }

    @Test func refusesToOpenNewerThanKnownVersion() throws {
        try withTempDatabase { url in
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)
                    """)
                try GrdbDatabaseFactory.writeVersion(db, Schema.version + 1)
            }
            #expect(throws: DatabaseOpenError.unsupported(onDiskSchemaVersion: Schema.version + 1)) {
                try GrdbDatabaseFactory.migrate(queue)
            }
        }
    }
}
