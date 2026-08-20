import Foundation
import PassesCore

/// The sealed supertype over Walt's stored document kinds (mirror of Android's
/// `sealed interface Document`, wpass-gyn / wpass-bsf; ios-dts.2). Shared fields live
/// here; every kind-specific field lives on its arm, never the supertype (`pageCount`
/// is PDF-only; `widthPx`/`heightPx` are image-only). `Document` shares no supertype
/// with `Pass` (ADR 0005 D1), and no `SignatureStatus` analogue exists for documents
/// (D5) — the trust caption is sourced from `provenance`.
///
/// Swift has no sealed protocols: the closed arm set
/// (`PDFDocument` | `ImageDocument` | `BarcodedImageDocument`) is pinned by
/// `documentArms` + `DocumentSealedSetTests`, so a new conformance must reconcile
/// the pin deliberately.
public protocol Document: Sendable {
    /// The arm's id through the supertype (Android's `val id: DocumentId`).
    /// Named `documentId` because each arm's concrete `id` keeps its precise type;
    /// existential note: `any DocumentId` reads `.value` but cannot key a
    /// `Set`/`Dictionary` — key off the concrete arm ids for that.
    var documentId: any DocumentId { get }
    var displayLabel: String { get }
    var byteCount: Int64 { get }
    var importedAtEpochMs: Int64 { get }
    var provenance: Provenance { get }
}

/// Per-arm ids under one supertype, so a PDF id cannot be substituted for an image id
/// in APIs that take the specific arm, while list-shaped consumers can still key off
/// `any DocumentId` (mirror of Android's `sealed interface DocumentId`).
public protocol DocumentId: Sendable, Hashable {
    var value: String { get }
}

/// The closed arm set — the executable stand-in for `sealed`. Kept in the source file
/// (not the test) so the pin and the arms travel together in review.
package let documentArms: [Any.Type] = [
    PDFDocument.self, ImageDocument.self, BarcodedImageDocument.self,
]

extension PDFDocument: Document {
    public var documentId: any DocumentId { id }
}
extension PDFDocumentId: DocumentId {}

/// Opaque identifier for a stored `ImageDocument`. Its own type (not `PDFDocumentId`)
/// so the compiler refuses a cross-kind substitution.
public struct ImageDocumentId: Sendable, Hashable, Equatable, DocumentId {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// The pure-Swift model for a successfully-imported still image (mirror of Android
/// `ImageDocument`, wpass-bsf; ios-dts.2). Sibling of `PDFDocument` under the sealed
/// `Document` supertype; the same D1/D4/D5 rules apply — no shared supertype with
/// `Pass`, `displayLabel` supplied by the consumer and never derived from content or
/// metadata, no signature verification.
///
/// `widthPx` / `heightPx` are the pixel dimensions of the bounded raster Walt decoded
/// through the in-process bounded decode (`PassesImage`, the §7-approved sandboxless
/// mirror of Android's isolated decode) — never derived from an in-process decode of
/// the untrusted source bytes outside that bounded path, and never upscaled beyond
/// the source. The original compressed bytes are persisted verbatim; these dimensions
/// are display/telemetry metadata, not a re-decoded canvas.
///
/// The model deliberately carries NO container format (PNG vs JPEG): the format is a
/// persistence detail handled by `PassesStorage`, and the display surface renders a
/// Walt-produced raster, not the original codec stream. Keeping format off the model
/// mirrors `PDFDocument` carrying no MIME and keeps `PassesPDFCore` free of the
/// image-format vocabulary, which lives one layer up in the importer.
public struct ImageDocument: Sendable, Equatable, Document {
    public var documentId: any DocumentId { id }

    public let id: ImageDocumentId
    public let displayLabel: String
    public let byteCount: Int64
    public let widthPx: Int
    public let heightPx: Int
    public let importedAtEpochMs: Int64
    public let provenance: Provenance

    public init(
        id: ImageDocumentId,
        displayLabel: String,
        byteCount: Int64,
        widthPx: Int,
        heightPx: Int,
        importedAtEpochMs: Int64,
        provenance: Provenance = .userProvided
    ) {
        self.id = id
        self.displayLabel = displayLabel
        self.byteCount = byteCount
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.importedAtEpochMs = importedAtEpochMs
        self.provenance = provenance
    }
}

/// Opaque identifier for a stored `BarcodedImageDocument`. Its own type so a
/// composite id cannot be substituted for a plain-image id (or vice versa).
public struct BarcodedImageDocumentId: Sendable, Hashable, Equatable, DocumentId {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// The composite artifact (mirror of Android `BarcodedImageDocument`, wpass-8lu;
/// ios-dts.3): a still image plus a barcode extracted from it, ONE artifact id
/// rendering as one wallet row — never a host-side join of an image entity and a
/// card entity.
///
/// `barcodePayload` is the VERBATIM decoded symbol contents; the consumer
/// re-encodes it across symbologies with `PassesCore.BarcodeEncoder` for the
/// detail-surface format switcher, so a single stored payload backs every
/// rendered symbology. It is untrusted text lifted out of image content —
/// display routes it through `BidiIsolation` (binding note on ios-dts.3).
/// `barcodeFormat` is the symbology the code was originally detected as.
///
/// The barcode half was produced by the bounded in-process barcode read lane
/// (`PassesBarcode`; §7-approved — on Android this ran in an isolated process and
/// only the pair crossed the binder, the C2 delta recorded in `image-decode-1`).
/// The image half is identical to `ImageDocument`: dimensions are the bounded
/// raster's, never a re-decoded canvas, and the model carries no container
/// format. When an imported image yields NO barcode the importer degrades to a
/// plain `ImageDocument` rather than a composite with an empty payload; the
/// model carries only what was FOUND, never why nothing was (the degrade reason
/// rides the persist seam, `BarcodeExtractionOutcome`). `displayLabel` is
/// consumer-supplied, never derived from EXIF/XMP or the payload (D4).
public struct BarcodedImageDocument: Sendable, Equatable, Document {
    public var documentId: any DocumentId { id }

    public let id: BarcodedImageDocumentId
    public let displayLabel: String
    public let byteCount: Int64
    public let widthPx: Int
    public let heightPx: Int
    public let barcodePayload: String
    public let barcodeFormat: ScannableFormat
    public let importedAtEpochMs: Int64
    public let provenance: Provenance

    public init(
        id: BarcodedImageDocumentId,
        displayLabel: String,
        byteCount: Int64,
        widthPx: Int,
        heightPx: Int,
        barcodePayload: String,
        barcodeFormat: ScannableFormat,
        importedAtEpochMs: Int64,
        provenance: Provenance = .userProvided
    ) {
        self.id = id
        self.displayLabel = displayLabel
        self.byteCount = byteCount
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.barcodePayload = barcodePayload
        self.barcodeFormat = barcodeFormat
        self.importedAtEpochMs = importedAtEpochMs
        self.provenance = provenance
    }
}

/// Default reflection would print `barcodePayload` verbatim (a BCBP payload
/// carries passenger name + PNR); redacted so a stray log of the model can
/// never leak it. Android's data-class `toString` does print the payload —
/// a deliberate iOS-ahead tightening of the no-PII-in-logs invariant.
extension BarcodedImageDocument: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "BarcodedImageDocument(id: \(id.value), displayLabel: \(displayLabel), "
            + "byteCount: \(byteCount), \(widthPx)x\(heightPx), "
            + "barcodePayload: <redacted \(barcodePayload.count) chars>, "
            + "barcodeFormat: \(barcodeFormat), importedAtEpochMs: \(importedAtEpochMs), "
            + "provenance: \(provenance))"
    }

    public var debugDescription: String { description }
}
