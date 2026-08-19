import Foundation
import UniformTypeIdentifiers

/// Defensive caps for the in-process bounded image decode-and-retain (mirror of
/// Android `ImageDecodeConfig`; §7-approved 2026-08-18, record on walt-ios ios-dts.2
/// and the `image-decode-1` ADR). The image-codec step is the dominant RCE and
/// decompression-bomb surface, so every dimension cap is enforced from the image
/// HEADER — before any bitmap is allocated. The numbers deliberately match
/// `BarcodeDecodeConfig` (Android records the same intent); the ALLOWLIST does not:
/// this retained lane admits JPEG and PNG only, per the §7 resolution.
///
/// Defaults are `static` constants so tests and the decoder share the numbers and
/// changing one is a deliberate, test-breaking edit.
public struct ImageDecodeConfig: Sendable {
    /// Max compressed bytes read off the source before any decode.
    public var maxBytes: Int
    /// Per-side header cap; an image advertising an absurd dimension trips it before
    /// allocation.
    public var maxDimensionPx: Int
    /// Megapixel header cap catching the small-file-huge-canvas bomb that stays under
    /// `maxDimensionPx` per axis.
    public var maxAreaPx: Int
    /// Wall-clock budget for the decode. Bounds the WAIT, not the work: iOS cannot
    /// kill an in-process decode the way Android's watchdog kills its sandbox process
    /// (the §7-priced containment delta; see the ADR).
    public var decodeTimeout: Duration
    /// Ceiling on the requested output raster's pixel count; an out-of-bounds request
    /// is a caller bug rejected before any byte is read.
    public var maxOutputPixels: Int
    /// The retained-lane container allowlist. §7 terms: JPEG/PNG ONLY — WebP dropped
    /// (worst CVE history, not an iPhone photo format), HEIF/HEIC not admitted
    /// natively (the gallery lane transcodes to JPEG out-of-process via PHPicker
    /// `.compatible` before Walt sees a byte). The five-container roster stays
    /// approved for the barcode READ lane (`BarcodeDecodeConfig`) only.
    public var allowedContentTypes: Set<UTType>

    public init(
        maxBytes: Int = Self.defaultMaxBytes,
        maxDimensionPx: Int = Self.defaultMaxDimensionPx,
        maxAreaPx: Int = Self.defaultMaxAreaPx,
        decodeTimeout: Duration = Self.defaultDecodeTimeout,
        maxOutputPixels: Int = Self.defaultMaxOutputPixels,
        allowedContentTypes: Set<UTType> = Self.defaultAllowedContentTypes
    ) {
        self.maxBytes = maxBytes
        self.maxDimensionPx = maxDimensionPx
        self.maxAreaPx = maxAreaPx
        self.decodeTimeout = decodeTimeout
        self.maxOutputPixels = maxOutputPixels
        self.allowedContentTypes = allowedContentTypes
    }

    /// Catches the large-file bomb shape; matches Android and the storage cap.
    public static let defaultMaxBytes = 25 * 1024 * 1024

    /// Per-side header cap.
    public static let defaultMaxDimensionPx = 12_000

    /// ~50 MP bounds the RGBA allocation to ~200 MB.
    public static let defaultMaxAreaPx = 50_000_000

    /// Bounded-wait budget (the Android watchdog's 5 s, minus the kill).
    public static let defaultDecodeTimeout: Duration = .milliseconds(5000)

    /// 4 MP (16 MB RGBA) — a 2048x2048 request sits exactly at this ceiling.
    public static let defaultMaxOutputPixels = 4 * 1024 * 1024

    /// §7 retained-lane allowlist: JPEG/PNG only.
    public static let defaultAllowedContentTypes: Set<UTType> = [.jpeg, .png]
}
