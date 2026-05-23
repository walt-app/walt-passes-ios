import Foundation

/// The on-disk schema. Single source of truth for table and column names, version, and
/// DDL statements. The production implementation executes `ddl` verbatim against the
/// SQLCipher-opened database; tests execute the same statements against an in-memory
/// SQLite to verify schema-roundtrip behavior without platform dependencies.
///
/// Bumping `version` requires a new entry in `migrations` and a corresponding test that
/// walks every prior version up to current. Forward-only: rollback is not supported, per
/// ADR 0002 (a downgraded build refuses to open the DB and surfaces
/// `StorageError.unsupported`).
public enum Schema {
    public static let databaseName: String = "walt_passes.db"

    public static let version: Int = 4

    public enum Tables {
        public static let schemaMeta: String = "schema_meta"
        public static let passes: String = "passes"
        public static let passImages: String = "pass_images"
        public static let passLocales: String = "pass_locales"
        public static let documents: String = "documents"
        public static let documentThumbnails: String = "document_thumbnails"
        public static let scannableCards: String = "scannable_cards"
    }

    public enum MetaKeys {
        public static let schemaVersion: String = "schema_version"
        public static let wrappedDbKey: String = "wrapped_db_key"
        public static let wrappedDbKeyIv: String = "wrapped_db_key_iv"
        public static let keyAlias: String = "key_alias"
        public static let keyBacking: String = "key_backing"
    }

    /// Statements that introduced the v3 scannable-cards table. Kept verbatim so a
    /// v2 -> v3 upgrade still produces the historical shape; the v3 -> v4 migration
    /// then rewrites the table. Fresh installs skip this and go straight to
    /// `v4ScannableCardTables`.
    private static let v3ScannableCardTables: [String] = [
        """
        CREATE TABLE IF NOT EXISTS scannable_cards (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            payload             TEXT    NOT NULL,
            format              TEXT    NOT NULL,
            label               TEXT    NOT NULL,
            color_argb          INTEGER,
            created_at_epoch_ms INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_scannable_cards_created_at " +
            "ON scannable_cards(created_at_epoch_ms)",
    ]

    /// Statements that introduce the v4 scannable-cards table — the v3 shape minus the
    /// `color_argb` column. Used by `ddl` for fresh installs at v4 and beyond. Existing
    /// v3 installs reach the same shape via the `v3ToV4DropColorColumn` table-rewrite
    /// migration.
    private static let v4ScannableCardTables: [String] = [
        """
        CREATE TABLE IF NOT EXISTS scannable_cards (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            payload             TEXT    NOT NULL,
            format              TEXT    NOT NULL,
            label               TEXT    NOT NULL,
            created_at_epoch_ms INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_scannable_cards_created_at " +
            "ON scannable_cards(created_at_epoch_ms)",
    ]

    /// v3 -> v4 migration. Drops the `color_argb` column from the scannable_cards table.
    /// Implemented as a table-rewrite (RENAME / CREATE / INSERT...SELECT / DROP) rather
    /// than `ALTER TABLE DROP COLUMN` so the migration works on every SQLCipher version
    /// the project ships on without depending on SQLite 3.35+ semantics. Row identity is
    /// preserved by re-using each row's explicit `id` in the INSERT; SQLite's
    /// AUTOINCREMENT bookkeeping in `sqlite_sequence` updates to max(id) on insert, so
    /// subsequent inserts do not collide with surviving rows.
    private static let v3ToV4DropColorColumn: [String] = [
        "ALTER TABLE scannable_cards RENAME TO scannable_cards_v3",
        """
        CREATE TABLE scannable_cards (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            payload             TEXT    NOT NULL,
            format              TEXT    NOT NULL,
            label               TEXT    NOT NULL,
            created_at_epoch_ms INTEGER NOT NULL
        )
        """,
        // Explicit column list intentional — SELECT * would pull color_argb and shift
        // column order on the target table.
        """
        INSERT INTO scannable_cards (id, payload, format, label, created_at_epoch_ms)
            SELECT id, payload, format, label, created_at_epoch_ms FROM scannable_cards_v3
        """,
        "DROP TABLE scannable_cards_v3",
        "CREATE INDEX IF NOT EXISTS idx_scannable_cards_created_at " +
            "ON scannable_cards(created_at_epoch_ms)",
    ]

    /// Statements that introduce the v2 document tables. Referenced from both `ddl` (for
    /// fresh installs) and `migrations[1]` (for v1 -> v2 upgrades) so the two paths
    /// cannot drift.
    private static let v2DocumentTables: [String] = [
        """
        CREATE TABLE IF NOT EXISTS documents (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            display_label       TEXT    NOT NULL,
            pdf_bytes           BLOB    NOT NULL,
            byte_count          INTEGER NOT NULL,
            page_count          INTEGER NOT NULL,
            imported_at_epoch_ms INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_documents_imported_at ON documents(imported_at_epoch_ms)",
        """
        CREATE TABLE IF NOT EXISTS document_thumbnails (
            document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            bytes       BLOB    NOT NULL,
            PRIMARY KEY (document_id)
        )
        """,
    ]

    /// The DDL block that brings a fresh database to `version`. Statements are listed in
    /// dependency order (parent tables before child tables); they are executed in a
    /// single transaction by the implementation.
    public static let ddl: [String] = ([
        """
        CREATE TABLE IF NOT EXISTS schema_meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value BLOB NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS passes (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            type                  TEXT    NOT NULL,
            serial_number         TEXT    NOT NULL,
            organization_name     TEXT    NOT NULL,
            description           TEXT    NOT NULL,
            expiration_epoch_ms   INTEGER,
            voided                INTEGER NOT NULL DEFAULT 0,
            signature_status_kind TEXT    NOT NULL,
            pass_json             BLOB    NOT NULL,
            created_at_epoch_ms   INTEGER NOT NULL,
            updated_at_epoch_ms   INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_passes_type ON passes(type)",
        "CREATE INDEX IF NOT EXISTS idx_passes_expiration ON passes(expiration_epoch_ms)",
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_passes_identity
            ON passes(type, serial_number, organization_name)
        """,
        """
        CREATE TABLE IF NOT EXISTS pass_images (
            pass_id INTEGER NOT NULL REFERENCES passes(id) ON DELETE CASCADE,
            role    TEXT    NOT NULL,
            bytes   BLOB    NOT NULL,
            PRIMARY KEY (pass_id, role)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS pass_locales (
            pass_id      INTEGER NOT NULL REFERENCES passes(id) ON DELETE CASCADE,
            locale_tag   TEXT    NOT NULL,
            strings_json BLOB    NOT NULL,
            PRIMARY KEY (pass_id, locale_tag)
        )
        """,
    ] + v2DocumentTables + v4ScannableCardTables)

    /// Schema migrations, keyed by `fromVersion`. Forward-only per ADR 0002. Each
    /// entry's statements are executed inside a single transaction; the
    /// `schema_meta.schema_version` row is bumped to `fromVersion + 1` in the same
    /// transaction so a partial upgrade is impossible.
    ///
    /// v1 -> v2 introduces `documents` and `document_thumbnails` for PDF document
    /// support (ADR 0005). The new tables live in the same SQLCipher database, so no
    /// XML / Auto Backup change is needed: the file-level exclusion already covers them.
    ///
    /// v2 -> v3 introduces `scannable_cards` for user-generated scannable artifacts.
    ///
    /// v3 -> v4 drops the now-unused `color_argb` column from `scannable_cards`. The
    /// consumer no longer reads or writes the field; the column was dormant
    /// user-private data on disk. Row identity is preserved; per-row colour bytes are
    /// lost, which is intentional — Walt already stopped reading them.
    public static let migrations: [Int: [String]] = [
        1: v2DocumentTables,
        2: v3ScannableCardTables,
        3: v3ToV4DropColorColumn,
    ]
}
