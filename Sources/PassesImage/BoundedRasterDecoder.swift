import CoreGraphics
import Foundation
import ImageIO
import PassesImageDecode
import UniformTypeIdentifiers

/// The bounded decode-and-fit pipeline (mirror of Android `BoundedRasterDecoder`,
/// wpass-6yp). Ordering is load-bearing and mirrors Android's:
///
///  1. The OUTPUT bound is validated first, before a single byte is read — an
///     out-of-bounds request is a caller bug (`decodeFailed`), not a source problem.
///  2. The compressed bytes are read bounded (`maxBytes + 1`, so an over-cap file is
///     detected without pulling the whole bomb into memory) → `oversizedAtImport`.
///  3. The shared `PassesImageDecode` primitive runs the header gate (container
///     allowlist, per-side cap, area cap) BEFORE any pixel allocation.
///  4. Only a gate-cleared image is materialized, then aspect-fitted into the
///     requested bounds — never upscaled.
enum BoundedRasterDecoder {
    static func decode(
        source: ImageDecodeSource,
        maxWidthPx: Int,
        maxHeightPx: Int,
        config: ImageDecodeConfig
    ) -> ImageDecodeResult {
        guard
            isOutputSizeValid(
                maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx,
                maxOutputPixels: config.maxOutputPixels)
        else {
            return .rejected(.decodeFailed)
        }
        guard let bytes = boundedBytes(source, maxBytes: config.maxBytes) else {
            // The read failed outright — the Android read-throw analogue.
            return .rejected(.decodeFailed)
        }
        if bytes.count > config.maxBytes {
            return .rejected(.oversizedAtImport)
        }
        let policy = BoundedDecodePolicy<ImageDecodeRejectedKind>(
            gate: { type, width, height in
                headerRejection(type: type, width: width, height: height, config: config)
            },
            onMalformed: { .notAnImage }
        )
        switch decodeBounded(rawBytes: bytes, policy: policy) {
        case .rejected(let kind):
            return .rejected(kind)
        case .decoded(let image):
            guard let raster = fitted(image, maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx)
            else {
                return .rejected(.decodeFailed)
            }
            return .ok(raster)
        }
    }

    /// Aspect-fit the decoded source into the requested bounds, never upscaling.
    /// A fit that needs no scale hands the decoded image through untouched.
    private static func fitted(
        _ image: CGImage, maxWidthPx: Int, maxHeightPx: Int
    ) -> ImageRaster? {
        let srcWidth = image.width
        let srcHeight = image.height
        guard srcWidth > 0, srcHeight > 0 else { return nil }
        let aspect = Float(srcWidth) / Float(srcHeight)
        let dims = outputDims(
            srcWidth: srcWidth, srcHeight: srcHeight,
            maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx)
        if dims.widthPx == srcWidth, dims.heightPx == srcHeight {
            return ImageRaster(
                image: image, widthPx: srcWidth, heightPx: srcHeight, sourceAspect: aspect)
        }
        guard
            let context = CGContext(
                data: nil, width: dims.widthPx, height: dims.heightPx,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: dims.widthPx, height: dims.heightPx))
        guard let scaled = context.makeImage() else { return nil }
        return ImageRaster(
            image: scaled, widthPx: dims.widthPx, heightPx: dims.heightPx, sourceAspect: aspect)
    }

    /// Read the source's compressed bytes, at most `maxBytes + 1`, so an over-cap
    /// source is detected without buffering the whole bomb. `nil` only when the
    /// source could not be read at all.
    private static func boundedBytes(_ source: ImageDecodeSource, maxBytes: Int) -> Data? {
        switch source {
        case .data(let data):
            return data
        case .fileURL(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: maxBytes + 1)
        }
    }
}

/// The header gate, pure so cap trips are testable without giant fixtures (Android
/// `headerRejection` mirror). Precedence: container, then per-side, then area.
func headerRejection(
    type: UTType?, width: Int, height: Int, config: ImageDecodeConfig
) -> ImageDecodeRejectedKind? {
    guard let type, config.allowedContentTypes.contains(where: { type.conforms(to: $0) })
    else { return .notAnImage }
    if width > config.maxDimensionPx || height > config.maxDimensionPx {
        return .dimensionsTooLarge
    }
    if width * height > config.maxAreaPx {
        return .dimensionsTooLarge
    }
    return nil
}

/// Mirror of Android `isOutputSizeValid`: positive bounds whose product sits within
/// the output-pixel ceiling.
func isOutputSizeValid(maxWidthPx: Int, maxHeightPx: Int, maxOutputPixels: Int) -> Bool {
    maxWidthPx > 0 && maxHeightPx > 0 && maxWidthPx * maxHeightPx <= maxOutputPixels
}

struct OutputDims: Equatable {
    let widthPx: Int
    let heightPx: Int
}

/// Mirror of Android `outputDims`: aspect-preserving fit, never upscaled (the `1`
/// clamp), each side coerced into `1...max`.
func outputDims(srcWidth: Int, srcHeight: Int, maxWidthPx: Int, maxHeightPx: Int) -> OutputDims {
    let fit = min(
        Float(maxWidthPx) / Float(srcWidth),
        Float(maxHeightPx) / Float(srcHeight),
        1
    )
    let width = min(max(Int((Float(srcWidth) * fit).rounded()), 1), maxWidthPx)
    let height = min(max(Int((Float(srcHeight) * fit).rounded()), 1), maxHeightPx)
    return OutputDims(widthPx: width, heightPx: height)
}
