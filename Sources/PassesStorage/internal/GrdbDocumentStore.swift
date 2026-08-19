import Foundation
import GRDB
import PassesCore

/// Document-table I/O: the `documents` row plus its cascaded `document_thumbnails` child.
/// Mirrors Android's `internal/SqlCipherDocumentStore.kt`. The document (PDF or image) and thumbnail blobs
/// round-trip as opaque bytes — the storage layer never parses, sniffs, or decodes them
/// (ADR 0005 D4). Every function takes the GRDB `Database` so the repository owns the
/// transaction boundary.
enum GrdbDocumentStore {
    static func listRows(_ db: Database) throws -> [DocumentRow] {
        try Row
            .fetchAll(
                db,
                sql: "SELECT id, display_label, byte_count, format, page_count, width_px, height_px, "
                    + "imported_at_epoch_ms, barcode_payload, barcode_format "
                    + "FROM \(Schema.Tables.documents) ORDER BY imported_at_epoch_ms DESC, id DESC"
            )
            .map { row in
                // A barcode is present only when BOTH columns decode: a payload with an
                // unrecognised format name (DB tampering only — this module is the sole
                // writer) reads back as no barcode rather than a half-composite.
                let payload: String? = row["barcode_payload"]
                let barcodeFormat = (row["barcode_format"] as String?)
                    .flatMap { ScannableFormat(dbValue: $0) }
                return DocumentRow(
                    id: DocumentRecordId(row["id"]),
                    displayLabel: row["display_label"],
                    byteCount: row["byte_count"],
                    // An unrecognised value (out-of-band DB tampering only) falls back
                    // to the pre-v7 default rather than throwing on a list query.
                    format: DocumentFormat(rawValue: row["format"]) ?? .pdf,
                    pageCount: row["page_count"],
                    widthPx: row["width_px"],
                    heightPx: row["height_px"],
                    importedAtEpochMs: row["imported_at_epoch_ms"],
                    barcodePayload: barcodeFormat == nil ? nil : payload,
                    barcodeFormat: payload == nil ? nil : barcodeFormat
                )
            }
    }

    /// Fields for a single document insert, flattened from the `DocumentInsert` arms by
    /// the repository. Grouped so `insert` stays within a sane parameter count;
    /// `byteCount` is derived inside `insert`, never caller-asserted. `widthPx` /
    /// `heightPx` are nil for PDF rows; the barcode pair is non-nil only for composites;
    /// `pageRasters` is empty for image rows (their thumbnail is the display raster).
    struct Insert {
        let label: String
        let bytes: Data
        let format: DocumentFormat
        let pageCount: Int
        let widthPx: Int?
        let heightPx: Int?
        let thumbnailBytes: Data
        let pageRasters: [DocumentPageRasterBlob]
        let barcodePayload: String?
        let barcodeFormat: ScannableFormat?
        let nowEpochMs: Int64
    }

    /// Inserts the document + thumbnail + page rasters in one transaction and returns the
    /// new id. The persisted `byte_count` is derived from `bytes.count` (not
    /// caller-asserted), so a stale size cannot bypass the cap.
    static func insert(_ doc: Insert, _ db: Database) throws -> DocumentRecordId {
        let byteCount = Int64(doc.bytes.count)
        try db.execute(
            sql: """
                INSERT INTO \(Schema.Tables.documents)
                    (display_label, pdf_bytes, byte_count, format, page_count,
                     width_px, height_px, imported_at_epoch_ms, barcode_payload, barcode_format)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                doc.label, doc.bytes, byteCount, doc.format.rawValue, doc.pageCount,
                doc.widthPx, doc.heightPx, doc.nowEpochMs, doc.barcodePayload,
                doc.barcodeFormat?.dbValue,
            ]
        )
        let rowId = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO \(Schema.Tables.documentThumbnails) (document_id, bytes) VALUES (?, ?)",
            arguments: [rowId, doc.thumbnailBytes]
        )
        try writePageRasters(documentId: rowId, doc.pageRasters, db)
        return DocumentRecordId(rowId)
    }

    /// Writes the raster rows for `documentId`, one row per page in order.
    static func writePageRasters(
        documentId: Int64,
        _ rasters: [DocumentPageRasterBlob],
        _ db: Database
    ) throws {
        for (index, raster) in rasters.enumerated() {
            try writePageRaster(documentId: documentId, page: index, raster, db)
        }
    }

    /// Insert-or-replace one page's raster row (the per-page self-heal backfill).
    static func writePageRaster(
        documentId: Int64,
        page: Int,
        _ raster: DocumentPageRasterBlob,
        _ db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(Schema.Tables.documentPageRasters)
                    (document_id, page_index, bytes, width_px, height_px)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [documentId, page, raster.bytes, raster.widthPx, raster.heightPx]
        )
    }

    static func loadPageRaster(
        id: DocumentRecordId,
        page: Int,
        _ db: Database
    ) throws -> DocumentPageRasterBlob? {
        try Row.fetchOne(
            db,
            sql: "SELECT bytes, width_px, height_px FROM \(Schema.Tables.documentPageRasters) "
                + "WHERE document_id = ? AND page_index = ?",
            arguments: [id.value, page]
        ).map { row in
            DocumentPageRasterBlob(bytes: row["bytes"], widthPx: row["width_px"], heightPx: row["height_px"])
        }
    }

    /// The row kind fields a raster read/backfill validates against: the stored
    /// `page_count` (the page-range reference) and the `format` discriminator (rasters
    /// belong to the PDF lane only). `nil` when no row matches `id`.
    struct RowKind {
        let pageCount: Int
        let format: DocumentFormat
    }

    static func rowKind(id: DocumentRecordId, _ db: Database) throws -> RowKind? {
        try Row.fetchOne(
            db,
            sql: "SELECT page_count, format FROM \(Schema.Tables.documents) WHERE id = ?",
            arguments: [id.value]
        ).map { row in
            RowKind(
                pageCount: row["page_count"],
                format: DocumentFormat(rawValue: row["format"]) ?? .pdf
            )
        }
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

    /// Deletes the document row (cascade drops the thumbnail and page rasters). Returns
    /// `false` if absent.
    static func delete(id: DocumentRecordId, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM \(Schema.Tables.documents) WHERE id = ?",
            arguments: [id.value]
        )
        return db.changesCount > 0
    }

    /// Overwrites `display_label` on the row matching `id`. `imported_at_epoch_ms` is left
    /// untouched. Returns `false` if no row matched (caller maps to integrityViolation).
    static func updateLabel(id: DocumentRecordId, label: String, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "UPDATE \(Schema.Tables.documents) SET display_label = ? WHERE id = ?",
            arguments: [label, id.value]
        )
        return db.changesCount > 0
    }

    /// Storage-side defense-in-depth (ADR 0005 D7): re-checks the size / page / label caps
    /// before any bytes reach disk, so a future caller bug cannot land an oversized row.
    /// Returns the rejected kind, or `nil` if the document is within bounds.
    static func rejection(
        bytes: Data,
        pageCount: Int,
        label: String
    ) -> DocumentStorageRejectedKind? {
        if Int64(bytes.count) > DocumentBounds.maxBytes { return .oversizedAtStorage }
        if pageCount > DocumentBounds.maxPages { return .tooManyPagesAtStorage }
        if label.count > DocumentBounds.maxLabelChars { return .labelTooLongAtStorage }
        return nil
    }

    /// Render-once completeness + bound check (ios-dts.16): the raster set must cover
    /// exactly `pageCount` pages and every raster must pass `rasterRejection`.
    static func pageRasterRejection(
        pageRasters: [DocumentPageRasterBlob],
        pageCount: Int
    ) -> DocumentStorageRejectedKind? {
        if pageRasters.count != pageCount { return .pageRastersInvalidAtStorage }
        for raster in pageRasters {
            if let kind = rasterRejection(raster) { return kind }
        }
        let total = pageRasters.reduce(Int64(0)) { $0 + Int64($1.bytes.count) }
        if total > DocumentBounds.maxTotalRasterBytes { return .pageRastersInvalidAtStorage }
        return nil
    }

    /// Sum of stored raster bytes for `documentId`, excluding `excludingPage` (the row a
    /// per-page backfill is about to replace) — the aggregate-cap reference for the
    /// singular write path.
    static func rasterBytesTotal(
        documentId: Int64,
        excludingPage: Int,
        _ db: Database
    ) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(LENGTH(bytes)), 0) FROM \(Schema.Tables.documentPageRasters) "
                + "WHERE document_id = ? AND page_index != ?",
            arguments: [documentId, excludingPage]
        ) ?? 0
    }

    /// Per-raster bound check: positive dimensions, the 4 MP pixel cap, and the encoded
    /// byte cap (the pixel cap alone leaves `bytes` the unbounded axis).
    static func rasterRejection(_ raster: DocumentPageRasterBlob) -> DocumentStorageRejectedKind? {
        if raster.widthPx <= 0 || raster.heightPx <= 0 {
            return .pageRastersInvalidAtStorage
        }
        // Per-side gate before the multiply: this is the defensive layer, so a
        // pathological declared dimension must reject, never trap the product.
        let sideCap = DocumentBounds.maxRasterPixels
        if Int64(raster.widthPx) > sideCap || Int64(raster.heightPx) > sideCap {
            return .pageRastersInvalidAtStorage
        }
        if Int64(raster.widthPx) * Int64(raster.heightPx) > DocumentBounds.maxRasterPixels {
            return .pageRastersInvalidAtStorage
        }
        if Int64(raster.bytes.count) > DocumentBounds.maxRasterBytes {
            return .pageRastersInvalidAtStorage
        }
        return nil
    }
}
