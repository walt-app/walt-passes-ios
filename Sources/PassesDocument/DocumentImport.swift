import Foundation
import PassesCore
import PassesImage
import PassesPDFCore

/// The single import entry point for user-supplied documents (mirror of Android
/// `DocumentImporter`, wpass-8lu; §7-approved ios-dts.3). Owns the trust-claim-
/// bearing orchestration walt-ios would otherwise reassemble: one bounded read of
/// the source, a byte-0-anchored magic sniff, the branch to the PDF or image
/// backend, the composite confirm seam, and the exactly-once persist hand-off.
///
/// `confirmBarcode` is the composite OPT-IN: nil (the default overload) means
/// barcode extraction does not run at all — an incidental barcode in a photo is
/// never silently turned into a composite, and a plain-image import pays zero
/// extraction cost. When supplied, the hook fires with the decoded
/// `(payload, format)` AFTER the image decode succeeds and BEFORE anything
/// persists; `true` persists a composite, `false` a plain image, a
/// `CancellationError` propagates (nothing persists), and any other throw is a
/// decline — a confirm-UI bug cannot fail the whole import.
///
/// `persist` is invoked exactly once on the success path, before the `imported*`
/// arm is constructed, and never on a rejection. `displayLabel` is forwarded
/// verbatim and never derived from EXIF/XMP or a barcode payload (ADR 0005 D4).
public protocol DocumentImporter: Sendable {
    func `import`(
        source: DocumentImportSource,
        displayLabel: String,
        confirmBarcode: (@Sendable (_ payload: String, _ format: ScannableFormat) async throws -> Bool)?,
        persist: @escaping @Sendable (DocumentPersist) async throws -> Void
    ) async throws -> DocumentImportResult
}

extension DocumentImporter {
    /// The composite opt-OUT shape: no hook, extraction never runs.
    public func `import`(
        source: DocumentImportSource,
        displayLabel: String,
        persist: @escaping @Sendable (DocumentPersist) async throws -> Void
    ) async throws -> DocumentImportResult {
        try await `import`(
            source: source, displayLabel: displayLabel, confirmBarcode: nil, persist: persist)
    }
}

/// Closed source shape (Android's two-arm discipline; iOS arms match the sibling
/// importers). The caller owns the source; over-cap `.fileURL` files are read
/// bounded (`maxBytes + 1`) so the chosen backend can observe and reject the
/// oversize without the importer buffering the whole file.
public enum DocumentImportSource: Sendable {
    case fileURL(URL)
    case data(Data)
}

public struct DocumentImportConfig: Sendable {
    /// Ceiling for the single bounded source read; matches the backends' caps.
    public var maxBytes: Int
    public var pdfConfig: PDFImportConfig
    public var imageTelemetryGuard: any ImageImportTelemetryGuard
    /// Square output bound handed to the bounded image decode for the display
    /// raster/thumbnail: aspect-preserving, never upscaled, and 2048 x 2048 sits
    /// exactly at the decoder's own 4 MP output ceiling.
    public var maxImageDecodePx: Int

    public init(
        maxBytes: Int = Int(PDFImportConfig.defaultMaxBytes),
        pdfConfig: PDFImportConfig = PDFImportConfig(),
        imageTelemetryGuard: any ImageImportTelemetryGuard = ImageImportTelemetryGuardNoOp.shared,
        maxImageDecodePx: Int = Self.defaultMaxImageDecodePx
    ) {
        self.maxBytes = maxBytes
        self.pdfConfig = pdfConfig
        self.imageTelemetryGuard = imageTelemetryGuard
        self.maxImageDecodePx = maxImageDecodePx
    }

    public static let defaultMaxImageDecodePx = 2048
}

/// The unified import outcome. The two reject arms REUSE each backend's own
/// taxonomy verbatim (the wpass-bsf decision) — there is deliberately no third
/// "document reject" enum to keep in sync; `unrecognized` and
/// `storageHandoffFailed` are the kind-agnostic arms.
public enum DocumentImportResult: Sendable {
    case importedPdf(PDFDocument)
    case importedImage(ImageDocument)
    case importedBarcodedImage(BarcodedImageDocument)
    case pdfRejected(DocumentRejectedKind)
    case imageRejected(ImageDecodeRejectedKind)
    case unrecognized
    case storageHandoffFailed
}

/// The three image containers the sniff can commit to (mirror of Android
/// `is.walt.passes.document.ImageFormat`). `webp` is sniffed — the RIFF check
/// stays meaningful — but the importer rejects it before any decode (the §7
/// retained-lane allowlist is JPEG/PNG only); it remains in the vocabulary so
/// the storage schema parity note holds.
public enum ImageFormat: Sendable, Equatable, CaseIterable {
    case png
    case jpeg
    case webp
}

/// What the importer hands `persist` (mirror of Android `DocumentPersist`).
/// `bytes` is always the ORIGINAL document bytes — persist them verbatim (the
/// "persist original" half of the import contract); `thumbnailBytes` is a
/// Walt-produced PNG (page-0 for a PDF, the bounded raster for an image). The
/// iOS `pdf` arm additionally carries the render-once `pageRasters`
/// (ios-dts.16), which Android does not store.
public enum DocumentPersist: Sendable, Equatable {
    case pdf(
        label: String, bytes: Data, thumbnailBytes: Data, pageCount: Int,
        pageRasters: [StoredPageRaster])
    case image(
        label: String, bytes: Data, thumbnailBytes: Data, format: ImageFormat,
        widthPx: Int, heightPx: Int, barcodeExtraction: BarcodeExtractionOutcome)
    case barcodedImage(
        label: String, bytes: Data, thumbnailBytes: Data, format: ImageFormat,
        widthPx: Int, heightPx: Int, barcodePayload: String, barcodeFormat: ScannableFormat)

    public var label: String {
        switch self {
        case .pdf(let label, _, _, _, _),
            .image(let label, _, _, _, _, _, _),
            .barcodedImage(let label, _, _, _, _, _, _, _):
            return label
        }
    }

    public var bytes: Data {
        switch self {
        case .pdf(_, let bytes, _, _, _),
            .image(_, let bytes, _, _, _, _, _),
            .barcodedImage(_, let bytes, _, _, _, _, _, _):
            return bytes
        }
    }

    public var thumbnailBytes: Data {
        switch self {
        case .pdf(_, _, let thumbnailBytes, _, _),
            .image(_, _, let thumbnailBytes, _, _, _, _),
            .barcodedImage(_, _, let thumbnailBytes, _, _, _, _, _):
            return thumbnailBytes
        }
    }
}

/// Why an image import stayed non-composite, named at the persist seam (mirror
/// of Android `BarcodeExtractionOutcome`, wpass-pl7.5). The arms are kept apart
/// because they call for different copy AND different affordances:
/// `failed(.decodeTimedOut)` is a load signal a user-initiated retry may clear,
/// `failed(.imageTooLarge)` never will, `noCodeFound` means the decode read the
/// image fine, and `declined` means the user already rejected the read. The
/// kernel names the reason; the app owns the copy.
///
/// NOTHING here carries the decoded payload or any image bytes: a BCBP boarding
/// pass payload carries passenger name and PNR, and
/// `DocumentPersist.barcodedImage` is the only place a payload crosses this seam
/// — and only after the user has confirmed it.
///
/// It rides the persist seam (the confirm sheet reads it there), not the stored
/// `ImageDocument`: it describes THIS import attempt, not the artifact. Swift
/// note: Android defaults the field to `NotAttempted` for caller ergonomics;
/// Swift enum payloads cannot default, and the importer is the only producer,
/// so it always passes explicitly.
public enum BarcodeExtractionOutcome: Sendable, Equatable {
    /// Nothing looked at the image (no hook supplied), so the absence of a code
    /// is unknown, not observed — distinct from `noCodeFound`.
    case notAttempted
    case noCodeFound
    case failed(reason: DecodeFailureReason)
    case declined
}
