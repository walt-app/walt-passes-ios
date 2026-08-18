import Foundation

/// Defensive caps `PassesStorage` re-checks before inserting a document row. The
/// authoritative source for size and page count is ADR 0005 D7; the renderer service in
/// `passes-pdf-core` enforces the same numbers at import time. Storage carries them a
/// second time so a future caller bug, a misconfigured renderer, or a new entry path
/// cannot land an oversized blob in the encrypted database.
///
/// `maxLabelChars` is enforced only here. Nothing upstream bounds the consumer-supplied
/// display label, and the column is used to render the indexed list view, so a multi-MB
/// string would inflate every list-view query.
///
/// Hardcoded here (rather than imported from `PassesPDFCore`) because `PassesStorage`
/// does not depend on `PassesPDFCore`: the `PdfDocument <-> documents-table` mapping is
/// a consumer-defined seam.
public enum DocumentBounds {
    public static let maxBytes: Int64 = 25 * 1024 * 1024
    public static let maxPages: Int = 10
    public static let maxLabelChars: Int = 256
    /// Per-page raster pixel cap (width * height). Mirrors the renderer's 4 MP output
    /// bound (`PDFKitRenderer.maxPixels`); storage re-checks it so a caller bug cannot
    /// land an unbounded first-party blob.
    public static let maxRasterPixels: Int64 = 4 * 1024 * 1024
    /// Per-page raster byte cap — the pixel cap alone leaves the encoded size unbounded.
    /// A 4 MP RGBA raw buffer is 16 MiB; a PNG materially above that is pathological
    /// (PNG of noise ≈ raw + filter overhead), so 20 MiB admits every legitimate encode.
    public static let maxRasterBytes: Int64 = 20 * 1024 * 1024
}

/// One Walt-produced page raster as stored in `document_page_rasters` (ios-dts.16
/// render-once). `bytes` is the PNG encode of the page rendered once at import;
/// `widthPx`/`heightPx` are the raster's own aspect-correct dimensions. The storage
/// layer never decodes the blob — it round-trips opaque, like `pdf_bytes`.
///
/// Deliberately a storage-local type (not `PassesPDFCore.StoredPageRaster`):
/// `PassesStorage` does not depend on the PDF modules, and the mapping between the two
/// shapes is the consumer's seam.
public struct DocumentPageRasterBlob: Sendable, Equatable {
    public let bytes: Data
    public let widthPx: Int
    public let heightPx: Int

    public init(bytes: Data, widthPx: Int, heightPx: Int) {
        self.bytes = bytes
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// The list-view projection of a stored PDF document. Mirrors the indexed columns of the
/// `documents` table; the heavy `pdf_bytes` and `document_thumbnails.bytes` blobs are NOT
/// loaded here. Consumers that need the bytes call `loadDocumentBytes` /
/// `loadDocumentThumbnail`.
public struct DocumentRow: Sendable, Equatable {
    public let id: DocumentRecordId
    public let displayLabel: String
    public let byteCount: Int64
    public let pageCount: Int
    public let importedAtEpochMs: Int64

    public init(
        id: DocumentRecordId,
        displayLabel: String,
        byteCount: Int64,
        pageCount: Int,
        importedAtEpochMs: Int64
    ) {
        self.id = id
        self.displayLabel = displayLabel
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.importedAtEpochMs = importedAtEpochMs
    }
}

/// Why a storage-side document insert was rejected. The arms mirror the renderer
/// service's import-time checks; storage refuses to land out-of-bounds rows so a future
/// caller bug cannot bypass the cap. The arms are deliberately suffixed `AtStorage` so
/// they cannot be confused with `PassesPDFCore`'s import-time `DocumentRejectedKind`,
/// which fires before bytes ever reach the storage layer.
public enum DocumentStorageRejectedKind: Sendable, CaseIterable {
    case oversizedAtStorage
    case tooManyPagesAtStorage
    case labelTooLongAtStorage
    /// The page-raster set does not line up with the document: wrong count (must equal
    /// `pageCount`) or a raster exceeding `DocumentBounds.maxRasterPixels`. Render-once
    /// (ios-dts.16) requires a complete, bounded raster set at insert.
    case pageRastersInvalidAtStorage
}
