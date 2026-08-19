import Foundation

/// The one entry point for the in-process bounded image decode-and-retain (mirror of
/// Android's `BoundedImageDecoder` facade, minus the bind/teardown — there is no
/// service to bind). Consumers hold the protocol, never the concrete type, so a
/// future out-of-process decoder (XPC) can drop in behind the same seam — the reason
/// `decoderUnavailable` stays in the taxonomy.
public protocol BoundedImageDecoder: Sendable {
    /// Decode `source` into an aspect-fitted, orientation-applied raster no larger
    /// than `maxWidthPx` x `maxHeightPx` (and never larger than the source). Every
    /// cap in `ImageDecodeConfig` is enforced before the corresponding allocation;
    /// the wait is bounded by `decodeTimeout`, reported as
    /// `.rejected(.decoderUnavailable)` — immediately when the lane bank refuses.
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
    /// Injectable so tests run against their own banks (parallel tests contend on
    /// the shared bank); production always uses `.shared` via the public factory.
    var lanes: ImageDecodeLanes = .shared

    func decode(
        source: ImageDecodeSource, maxWidthPx: Int, maxHeightPx: Int
    ) async -> ImageDecodeResult {
        let config = self.config
        // The I/O-free preflight runs OUTSIDE the lanes: an out-of-bounds request
        // or an over-cap `.data` source rejects with its real arm even when every
        // lane is busy, and never occupies one. The `.fileURL` read runs INSIDE
        // the lane so a slow source is covered by the bounded wait.
        let preflight = BoundedRasterDecoder.preflight(
            source: source, maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx, config: config)
        if case .rejected(let kind) = preflight {
            return .rejected(kind)
        }
        return await withImageDecodeTimeout(
            config.decodeTimeout,
            lanes: lanes,
            timeoutValue: .rejected(.decoderUnavailable)
        ) {
            BoundedRasterDecoder.decodeOnLane(
                source: source, maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx,
                config: config)
        }
    }
}
