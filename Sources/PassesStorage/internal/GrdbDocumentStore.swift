import Foundation
import GRDB

/// Document-table I/O: the `documents` row plus its cascaded `document_thumbnails` child.
/// Mirrors Android's `internal/SqlCipherDocumentStore.kt`. The PDF and thumbnail blobs
/// round-trip as opaque bytes — the storage layer never parses, sniffs, or decodes them
/// (ADR 0005 D4). Every function takes the GRDB `Database` so the repository owns the
/// transaction boundary.
enum GrdbDocumentStore {
    static func listRows(_ db: Database) throws -> [DocumentRow] {
        try Row
            .fetchAll(
                db,
                sql: "SELECT id, display_label, byte_count, page_count, imported_at_epoch_ms "
                    + "FROM \(Schema.Tables.documents) ORDER BY imported_at_epoch_ms DESC, id DESC"
            )
            .map { row in
                DocumentRow(
                    id: DocumentRecordId(row["id"]),
                    displayLabel: row["display_label"],
                    byteCount: row["byte_count"],
                    pageCount: row["page_count"],
                    importedAtEpochMs: row["imported_at_epoch_ms"]
                )
            }
    }

    /// Inserts the document + thumbnail in one transaction and returns the new id. The
    /// persisted `byte_count` is derived from `pdfBytes.count` (not caller-asserted), so a
    /// stale size cannot bypass the cap.
    static func insert(
        label: String,
        pdfBytes: Data,
        pageCount: Int,
        thumbnailBytes: Data,
        nowEpochMs: Int64,
        _ db: Database
    ) throws -> DocumentRecordId {
        let byteCount = Int64(pdfBytes.count)
        try db.execute(
            sql: """
                INSERT INTO \(Schema.Tables.documents)
                    (display_label, pdf_bytes, byte_count, page_count, imported_at_epoch_ms)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [label, pdfBytes, byteCount, pageCount, nowEpochMs]
        )
        let rowId = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO \(Schema.Tables.documentThumbnails) (document_id, bytes) VALUES (?, ?)",
            arguments: [rowId, thumbnailBytes]
        )
        return DocumentRecordId(rowId)
    }

    static func loadBytes(id: DocumentRecordId, _ db: Database) throws -> Data? {
        try Row.fetchOne(
            db,
            sql: "SELECT pdf_bytes FROM \(Schema.Tables.documents) WHERE id = ?",
            arguments: [id.value]
        ).map { $0["pdf_bytes"] }
    }

    static func loadThumbnail(id: DocumentRecordId, _ db: Database) throws -> Data? {
        try Row.fetchOne(
            db,
            sql: "SELECT bytes FROM \(Schema.Tables.documentThumbnails) WHERE document_id = ?",
            arguments: [id.value]
        ).map { $0["bytes"] }
    }

    /// Deletes the document row (cascade drops the thumbnail). Returns `false` if absent.
    static func delete(id: DocumentRecordId, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM \(Schema.Tables.documents) WHERE id = ?",
            arguments: [id.value]
        )
        return db.changesCount > 0
    }

    /// Storage-side defense-in-depth (ADR 0005 D7): re-checks the size / page / label caps
    /// before any bytes reach disk, so a future caller bug cannot land an oversized row.
    /// Returns the rejected kind, or `nil` if the document is within bounds.
    static func rejection(
        pdfBytes: Data,
        pageCount: Int,
        label: String
    ) -> DocumentStorageRejectedKind? {
        if Int64(pdfBytes.count) > DocumentBounds.maxBytes { return .oversizedAtStorage }
        if pageCount > DocumentBounds.maxPages { return .tooManyPagesAtStorage }
        if label.count > DocumentBounds.maxLabelChars { return .labelTooLongAtStorage }
        return nil
    }
}
