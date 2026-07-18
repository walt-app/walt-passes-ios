import Foundation
import UniformTypeIdentifiers

/// Defensive caps for the bounded still-image decode (mirror of Android `BarcodeDecodeConfig`).
/// The image-codec step is the dominant RCE (CVE-2023-4863 libwebp class) and decompression-bomb
/// surface, so every cap here is enforced from the image *header* — before `CGImageSource`
/// allocates a bitmap. Per-cap specifics are on each property.
///
/// Defaults are `static` constants so tests and the decoder share the numbers and changing one is a
/// deliberate, test-breaking edit.
public struct BarcodeDecodeConfig: Sendable {
    /// Max compressed bytes read off the source before any decode.
    public var maxBytes: Int
    /// Per-side header cap; an image advertising an absurd dimension trips it before allocation.
    public var maxDimensionPx: Int
    /// Megapixel header cap catching the small-file-huge-canvas bomb that stays under
    /// ``maxDimensionPx`` per axis.
    public var maxAreaPx: Int
    /// Wall-clock budget for the Vision decode; on expiry the decoder reports
    /// `decoderUnavailable` (the app-level `ProcessKiller` analogue).
    public var decodeTimeout: Duration
    /// Still-image containers a card photo realistically arrives in; others are refused before decode.
    public var allowedContentTypes: Set<UTType>

    public init(
        maxBytes: Int = Self.defaultMaxBytes,
        maxDimensionPx: Int = Self.defaultMaxDimensionPx,
        maxAreaPx: Int = Self.defaultMaxAreaPx,
        decodeTimeout: Duration = Self.defaultDecodeTimeout,
        allowedContentTypes: Set<UTType> = Self.defaultAllowedContentTypes
    ) {
        self.maxBytes = maxBytes
        self.maxDimensionPx = maxDimensionPx
        self.maxAreaPx = maxAreaPx
        self.decodeTimeout = decodeTimeout
        self.allowedContentTypes = allowedContentTypes
    }

    /// Catches the large-file bomb shape; mirrors Android's 25 MB (and passes storage's cap).
    public static let defaultMaxBytes = 25 * 1024 * 1024

    /// Per-side header cap; a bomb advertising absurd dimensions trips it before allocation.
    public static let defaultMaxDimensionPx = 12_000

    /// ~50 MP bounds the RGBA allocation to ~200 MB, catching the huge-canvas bomb.
    public static let defaultMaxAreaPx = 50_000_000

    /// Decode wall-clock budget; on expiry the decoder reports `decoderUnavailable` (slow-loris guard).
    public static let defaultDecodeTimeout: Duration = .milliseconds(5000)

    /// Still-image containers a card photo realistically arrives in; others are refused before decode.
    public static let defaultAllowedContentTypes: Set<UTType> = [
        .jpeg,
        .png,
        .webP,
        .heic,
        .heif,
    ]
}
