import Foundation
import PassesCore

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
    /// Per-page raster pixel cap (width * height) over the CALLER-DECLARED dimensions —
    /// storage never decodes the blob, so this bounds what callers assert, not what the
    /// PNG header says; the display layer's own decode ceilings are the second line.
    /// Mirrors the renderer's 4 MP output bound (`PDFKitRenderer.maxPixels`).
    public static let maxRasterPixels: Int64 = 4 * 1024 * 1024
    /// Per-page raster byte cap — the pixel cap alone leaves the encoded size unbounded.
    /// A 4 MP RGBA raw buffer is 16 MiB; a PNG materially above that is pathological
    /// (PNG of noise ≈ raw + filter overhead), so 20 MiB admits every legitimate encode.
    public static let maxRasterBytes: Int64 = 20 * 1024 * 1024
    /// Aggregate byte cap over a document's whole raster set — the per-raster caps alone
    /// admit a ~200 MiB set (10 pages x 20 MiB). 4x the source cap bounds the silent
    /// on-disk amplification while admitting a measured photographic 10-pager
    /// (~6-10 MiB per 4 MP PNG page). A legitimate rejection here is the signal to
    /// reconsider PNG for photographic pages, not to raise the bound.
    public static let maxTotalRasterBytes: Int64 = 4 * DocumentBounds.maxBytes
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

/// The container kind of a stored document — the `documents.format` discriminator
/// (mirror of Android `DocumentFormat`, wpass-i9x). The storage layer keeps its own enum
/// because `PassesStorage` is an independent peer of the document modules: the
/// `Document <-> documents-table` mapping is a consumer-defined seam. Persisted as the
/// raw value ('pdf' / 'png' / 'jpeg' / 'webp'). `webp` stays in the value space to keep
/// the schema vocabulary mirrored to Android, but is enforced-unreachable at the iOS
/// importer sniff (§7 resolution on ios-dts.2: the retained-image lane admits JPEG/PNG
/// only).
///
/// Adding a case MUST come with a schema-version bump: without one, an older build
/// reading the new value falls back to `.pdf` — the one non-tampering trigger for the
/// permissive fallback — where the `unsupported` downgrade refusal would otherwise
/// stop it.
public enum DocumentFormat: String, Sendable, CaseIterable {
    case pdf
    case png
    case jpeg
    case webp
}

/// What `PassRepository.insertDocument` persists, as a sealed discriminator over the
/// document kinds the `documents` table holds (mirror of Android `DocumentInsert`,
/// wpass-i9x / wpass-8lu). Each arm carries exactly the kind-specific
/// fields, so the field mixes the type can prevent are unrepresentable (an image with
/// a page count, a PDF with dimensions). `bytes` is the ORIGINAL document bytes (PDF or compressed image);
/// storage round-trips them opaque. `thumbnailBytes` is the Walt-produced display
/// raster, PNG-encoded upstream.
///
/// iOS deviation from the Android shape: the `pdf` arm additionally carries
/// `pageRasters` — the render-once per-page display rasters (ios-dts.16), which Android
/// does not store (it re-renders per open inside its sandbox). The image arms carry no
/// rasters: their `thumbnailBytes` IS the single Walt-produced display raster.
public enum DocumentInsert: Sendable {
    case pdf(
        label: String, bytes: Data, thumbnailBytes: Data, pageCount: Int,
        pageRasters: [DocumentPageRasterBlob])
    /// A still image. `format` must be one of the image arms of `DocumentFormat` —
    /// passing `.pdf` here is a caller bug (Android parity: documented, not rejected).
    case image(
        label: String, bytes: Data, thumbnailBytes: Data, format: DocumentFormat,
        widthPx: Int, heightPx: Int)
    /// A composite (image + extracted barcode) persisted as ONE row. A composite is
    /// always image-backed: passing `.pdf` as `format` is a caller bug here too.
    case barcodedImage(
        label: String, bytes: Data, thumbnailBytes: Data, format: DocumentFormat,
        widthPx: Int, heightPx: Int, barcodePayload: String, barcodeFormat: ScannableFormat)

    /// Shared accessors, mirroring the Android sealed interface's common vals.
    public var label: String {
        switch self {
        case .pdf(let label, _, _, _, _),
            .image(let label, _, _, _, _, _),
            .barcodedImage(let label, _, _, _, _, _, _, _):
            return label
        }
    }

    public var bytes: Data {
        switch self {
        case .pdf(_, let bytes, _, _, _),
            .image(_, let bytes, _, _, _, _),
            .barcodedImage(_, let bytes, _, _, _, _, _, _):
            return bytes
        }
    }

    public var thumbnailBytes: Data {
        switch self {
        case .pdf(_, _, let thumbnailBytes, _, _),
            .image(_, _, let thumbnailBytes, _, _, _),
            .barcodedImage(_, _, let thumbnailBytes, _, _, _, _, _):
            return thumbnailBytes
        }
    }
}

/// The list-view projection of a stored document (PDF or image). Mirrors the indexed
/// columns of the `documents` table; the heavy `pdf_bytes` and
/// `document_thumbnails.bytes` blobs are NOT loaded here. Consumers that need the bytes
/// call `loadDocumentBytes` / `loadDocumentThumbnail`.
public struct DocumentRow: Sendable, Equatable {
    public let id: DocumentRecordId
    public let displayLabel: String
    public let byteCount: Int64
    /// The kind discriminator a consumer branches on: `.pdf` uses `pageCount`; the
    /// image formats use `widthPx` / `heightPx` (with `pageCount` 1 — an image is a
    /// single page).
    public let format: DocumentFormat
    public let pageCount: Int
    public let widthPx: Int?
    public let heightPx: Int?
    public let importedAtEpochMs: Int64
    /// Non-nil ONLY for a composite artifact (wpass-8lu): an image row that also
    /// carries a barcode extracted from it. Always nil for PDF and plain image rows;
    /// the pair is the composite discriminator on top of the image `format`.
    public let barcodePayload: String?
    public let barcodeFormat: ScannableFormat?

    public init(
        id: DocumentRecordId,
        displayLabel: String,
        byteCount: Int64,
        format: DocumentFormat,
        pageCount: Int,
        widthPx: Int? = nil,
        heightPx: Int? = nil,
        importedAtEpochMs: Int64,
        barcodePayload: String? = nil,
        barcodeFormat: ScannableFormat? = nil
    ) {
        self.id = id
        self.displayLabel = displayLabel
        self.byteCount = byteCount
        self.format = format
        self.pageCount = pageCount
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.importedAtEpochMs = importedAtEpochMs
        self.barcodePayload = barcodePayload
        self.barcodeFormat = barcodeFormat
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
