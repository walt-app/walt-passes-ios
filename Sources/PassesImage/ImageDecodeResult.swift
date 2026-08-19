import CoreGraphics
import Foundation

/// The reasons an image decode can be rejected, as its OWN closed taxonomy —
/// deliberately NOT flattened into `PassesPDFCore`'s `DocumentRejectedKind` (mirror
/// of Android's `ImageDecodeRejectedKind`; the wpass-i9x acceptance criterion). The
/// two document kinds fail in different ways (a PDF is encrypted or has too many
/// pages; an image is not-an-image or a decompression bomb), and folding them into
/// one enum would force each consumer to branch on arms that cannot occur for its
/// kind.
///
/// Telemetry-safe by construction: payload-free arms, no string ever attached,
/// matching the `DocumentRejectedKind` / `DecodeFailureReason` discipline.
public enum ImageDecodeRejectedKind: Sendable, Equatable, CaseIterable {
    /// The container is outside the retained-lane allowlist, or the bytes did not
    /// decode as an image at all (the MIME-spoof / wrong-file case).
    case notAnImage
    /// The compressed bytes exceeded the file-size cap before any decode; the
    /// oversized buffer is never fully read.
    case oversizedAtImport
    /// The header advertised over-cap dimensions or area (the decompression-bomb
    /// shape), refused before any bitmap allocation.
    case dimensionsTooLarge
    /// The decode or the raster fit failed after the header cleared, or the caller
    /// requested an out-of-bounds output size. The underlying codec error is never
    /// reported.
    case decodeFailed
    /// The decode did not return within the bounded wait. On Android this arm means
    /// the sandbox process went away (watchdog kill); in-process iOS keeps the arm
    /// for taxonomy parity and as the timeout bucket — the §7-priced containment
    /// delta is recorded in the `image-decode-1` ADR.
    case decoderUnavailable
}

/// A successfully decoded, aspect-fitted, never-upscaled raster. The pixel payload
/// is Walt-produced output of the bounded decode — the retained-display contract's
/// input, not the untrusted source bytes.
///
/// `@unchecked Sendable`: `CGImage` is an immutable object documented safe to read
/// from any thread; this wrapper adds only immutable value fields (the doc comment
/// is the ADR per the repo's `@unchecked Sendable` policy).
public struct ImageRaster: @unchecked Sendable {
    public let image: CGImage
    public let widthPx: Int
    public let heightPx: Int
    /// Width over height of the DECODED SOURCE (pre-fit), so a display surface can
    /// letterbox without re-reading the original.
    public let sourceAspect: Float

    public init(image: CGImage, widthPx: Int, heightPx: Int, sourceAspect: Float) {
        self.image = image
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.sourceAspect = sourceAspect
    }
}

public enum ImageDecodeResult: Sendable {
    case ok(ImageRaster)
    case rejected(ImageDecodeRejectedKind)
}

/// Closed source shape for the bounded decode (mirror of Android's two-arm
/// `ImageSource` discipline — no path-string arm, so every source is either bytes
/// the caller already owns or a file the OS opens for us). Recorded deviation:
/// Android forbids a byte-array arm because bytes in the caller's heap would defeat
/// its process sandbox; in-process iOS has no sandbox to defeat, and the importer
/// (ios-dts.3) reads its source once into bytes before sniffing, so `.data` is the
/// primary arm here.
public enum ImageDecodeSource: Sendable {
    case data(Data)
    case fileURL(URL)
}
