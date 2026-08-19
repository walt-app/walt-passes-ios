import Foundation

/// The one entry point for the in-process bounded image decode-and-retain (mirror of
/// Android's `BoundedImageDecoder` facade, minus the bind/teardown — there is no
/// service to bind). Consumers hold the protocol, never the concrete type, so a
/// future out-of-process decoder (XPC) can drop in behind the same seam — the reason
/// `decoderUnavailable` stays in the taxonomy.
public protocol BoundedImageDecoder: Sendable {
    /// Decode `source` into an aspect-fitted raster no larger than
    /// `maxWidthPx` x `maxHeightPx` (and never larger than the source). Every cap in
    /// `ImageDecodeConfig` is enforced before the corresponding allocation; the wait
    /// is bounded by `decodeTimeout`, reported as `.rejected(.decoderUnavailable)`.
    func decode(
        source: ImageDecodeSource, maxWidthPx: Int, maxHeightPx: Int
    ) async -> ImageDecodeResult
}

/// Production factory. The concrete decoder is package-private so test seams stay
/// off the public surface (sibling of `makePDFImporter` / `makePDFRenderer`).
public func makeBoundedImageDecoder(
    config: ImageDecodeConfig = ImageDecodeConfig()
) -> any BoundedImageDecoder {
    DefaultBoundedImageDecoder(config: config)
}

struct DefaultBoundedImageDecoder: BoundedImageDecoder {
    let config: ImageDecodeConfig

    func decode(
        source: ImageDecodeSource, maxWidthPx: Int, maxHeightPx: Int
    ) async -> ImageDecodeResult {
        let config = self.config
        return await withImageDecodeTimeout(
            config.decodeTimeout,
            timeoutValue: .rejected(.decoderUnavailable)
        ) {
            BoundedRasterDecoder.decode(
                source: source, maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx,
                config: config)
        }
    }
}
