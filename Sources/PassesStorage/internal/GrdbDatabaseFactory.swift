import Foundation
import GRDB

/// Opens the passes database and brings it to the current `Schema.version`.
///
/// Mirrors Android's `internal/SqlCipherDatabaseFactory.kt`, adapted to the iOS
/// Data Protection model (ios-b1f epic decision 2026-06-02): there is NO SQLCipher
/// `PRAGMA key`. Encryption-at-rest is the OS-managed `FileProtectionType.complete`
/// attribute applied to the DB file and its sidecars, so this factory carries no
/// `PassKeyProvider`. The class is named for the actual technology (GRDB + vanilla
/// SQLite) rather than Android's `SqlCipher*` name, so a future security reviewer is
/// not misled into thinking a SQLCipher key is in play. Android name:
/// `SqlCipherDatabaseFactory`.
///
/// Migration is forward-only and version-tracked in the `schema_meta` table (per the
/// kernel `Schema` contract / ADR 0002): a fresh file runs `Schema.ddl` and records the
/// current version; an older file walks `Schema.migrations` one version at a time; a
/// newer-than-known file refuses to open with `.unsupported`. The whole bring-up runs in
/// a single write transaction, so a partial upgrade cannot land.
enum GrdbDatabaseFactory {
    /// Open (creating if absent) the database at `url`, apply Data Protection, and migrate
    /// it to `Schema.version`. Throws `DatabaseOpenError` for a downgrade or a missing
    /// migration step; rethrows GRDB / SQLite errors otherwise.
    static func open(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try applyFileProtection(at: url)
        try migrate(queue)
        return queue
    }

    // MARK: - Migration

    static func migrate(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            guard let onDisk = try readVersion(db) else {
                // Fresh database: run the full DDL and stamp the current version.
                for statement in Schema.ddl {
                    try db.execute(sql: statement)
                }
                try writeVersion(db, Schema.version)
                return
            }

            if onDisk > Schema.version {
                throw DatabaseOpenError.unsupported(onDiskSchemaVersion: onDisk)
            }

            var version = onDisk
            while version < Schema.version {
                guard let statements = Schema.migrations[version] else {
                    throw DatabaseOpenError.missingMigration(fromVersion: version)
                }
                for statement in statements {
                    try db.execute(sql: statement)
                }
                version += 1
                try writeVersion(db, version)
            }
        }
    }

    // MARK: - schema_meta version row

    /// Returns the on-disk schema version, or `nil` if the `schema_meta` table or its
    /// version row is absent (i.e. a fresh database).
    static func readVersion(_ db: Database) throws -> Int? {
        guard try db.tableExists(Schema.Tables.schemaMeta) else { return nil }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT value FROM \(Schema.Tables.schemaMeta) WHERE key = ?",
            arguments: [Schema.MetaKeys.schemaVersion]
        )
        guard let data: Data = row?["value"] else { return nil }
        return Int(String(decoding: data, as: UTF8.self))
    }

    /// The version is stored as the decimal string in the `value` BLOB column. iOS passes
    /// databases never cross to Android, so byte-for-byte parity with Android's encoding is
    /// unnecessary; a decimal string keeps the row human-readable when inspecting the DB.
    static func writeVersion(_ db: Database, _ version: Int) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.Tables.schemaMeta) (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [Schema.MetaKeys.schemaVersion, Data(String(version).utf8)]
        )
    }

    // MARK: - Data Protection

    #if os(iOS)
    /// Marks the DB file and its WAL/SHM/journal sidecars `FileProtectionType.complete`:
    /// the OS keeps them encrypted at rest and inaccessible while the device is locked.
    /// This replaces Android's SQLCipher page encryption (ios-b1f decision). The companion
    /// backup-exclusion / sidecar assertion lands in E5.
    static func applyFileProtection(at url: URL) throws {
        let fileManager = FileManager.default
        let paths = [
            url.path,
            url.path + "-wal",
            url.path + "-shm",
            url.path + "-journal",
        ]
        for path in paths where fileManager.fileExists(atPath: path) {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: path
            )
        }
    }
    #else
    /// Data Protection is an iOS-only capability; on macOS (where the kernel's `swift test`
    /// runs) the attribute has no effect, so applying it is a documented no-op. Production
    /// runs only on iOS.
    static func applyFileProtection(at url: URL) throws {}
    #endif
}

/// Failure modes raised while bringing the database to the current schema version. Mapped
/// to `StorageError` (`.unsupported` / `.unknown(.databaseCorrupt)`) by the repository.
enum DatabaseOpenError: Error, Equatable {
    /// The on-disk schema version is newer than this build understands (a downgrade).
    case unsupported(onDiskSchemaVersion: Int)
    /// An intermediate version has no registered migration — a schema-definition bug.
    case missingMigration(fromVersion: Int)
}
