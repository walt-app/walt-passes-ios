import CoreGraphics
import Foundation
import ImageIO
import PassesImageDecode
import UniformTypeIdentifiers

/// The bounded decode-and-fit pipeline (mirror of Android `BoundedRasterDecoder`,
/// wpass-6yp). The output bound is validated first — before a single byte is read —
/// so an out-of-bounds request is reported as the caller bug it is (`decodeFailed`),
/// never as a source problem; then the bounded byte read, the header gates (via the
/// shared `PassesImageDecode` primitive), and only then materialization and the
/// aspect-fit, which never upscales and applies the header's EXIF orientation
/// (ImageIO returns STORED pixels; Android's `ImageDecoder` orients for you).
enum BoundedRasterDecoder {
    /// The codec-free preflight (output bound, bounded read, byte cap), split out so
    /// the facade can run it OUTSIDE the decode lanes: a rejection here never
    /// occupies a lane and can never be masked by lane refusal.
    enum Preflight {
        case ok(Data)
        case rejected(ImageDecodeRejectedKind)
    }

    static func preflight(
        source: ImageDecodeSource,
        maxWidthPx: Int,
        maxHeightPx: Int,
        config: ImageDecodeConfig
    ) -> Preflight {
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
        return .ok(bytes)
    }

    /// The codec half: header gates, materialization, orientation-aware fit. Runs
    /// on a decode lane under the bounded wait.
    static func decodePreflighted(
        bytes: Data,
        maxWidthPx: Int,
        maxHeightPx: Int,
        config: ImageDecodeConfig
    ) -> ImageDecodeResult {
        let policy = BoundedDecodePolicy<ImageDecodeRejectedKind>(
            containerGate: { type in containerRejection(type: type, config: config) },
            dimensionGate: { width, height in
                dimensionRejection(width: width, height: height, config: config)
            },
            onMalformed: { .notAnImage },
            onDecodeFailed: { .decodeFailed }
        )
        switch decodeBounded(rawBytes: bytes, policy: policy) {
        case .rejected(let kind):
            return .rejected(kind)
        case .decoded(let image):
            let orientation = headerOrientation(rawBytes: bytes)
            guard
                let raster = fitted(
                    image, orientation: orientation,
                    maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx)
            else {
                return .rejected(.decodeFailed)
            }
            return .ok(raster)
        }
    }

    /// Aspect-fit the decoded source into the requested bounds, never upscaling,
    /// applying `orientation` (EXIF 1...8) so a portrait phone JPEG comes out
    /// upright and its PERSISTED dimensions are the display dimensions.
    private static func fitted(
        _ image: CGImage, orientation: Int, maxWidthPx: Int, maxHeightPx: Int
    ) -> ImageRaster? {
        let storedWidth = image.width
        let storedHeight = image.height
        guard storedWidth > 0, storedHeight > 0 else { return nil }
        // Orientations 5-8 transpose the displayed axes.
        let transposed = orientation >= 5
        let srcWidth = transposed ? storedHeight : storedWidth
        let srcHeight = transposed ? storedWidth : storedHeight
        let aspect = Float(srcWidth) / Float(srcHeight)
        let dims = outputDims(
            srcWidth: srcWidth, srcHeight: srcHeight,
            maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx)
        if orientation == 1, dims.widthPx == srcWidth, dims.heightPx == srcHeight {
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
        applyOrientationTransform(
            context, orientation: orientation,
            outputWidth: dims.widthPx, outputHeight: dims.heightPx)
        // Under the transform, draw at the STORED axes scaled to the output.
        let drawWidth = transposed ? dims.heightPx : dims.widthPx
        let drawHeight = transposed ? dims.widthPx : dims.heightPx
        context.draw(image, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        guard let scaled = context.makeImage() else { return nil }
        return ImageRaster(
            image: scaled, widthPx: dims.widthPx, heightPx: dims.heightPx, sourceAspect: aspect)
    }

    /// Concatenate the CG transform that maps EXIF orientation `orientation` onto an
    /// upright output of `outputWidth` x `outputHeight`.
    private static func applyOrientationTransform(
        _ context: CGContext, orientation: Int, outputWidth: Int, outputHeight: Int
    ) {
        let width = CGFloat(outputWidth)
        let height = CGFloat(outputHeight)
        switch orientation {
        case 2:  // mirrored horizontal
            context.translateBy(x: width, y: 0)
            context.scaleBy(x: -1, y: 1)
        case 3:  // rotated 180
            context.translateBy(x: width, y: height)
            context.rotate(by: .pi)
        case 4:  // mirrored vertical
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
        case 5:  // mirrored horizontal, rotated 270 CW
            context.rotate(by: .pi / 2)
            context.scaleBy(x: 1, y: -1)
        case 6:  // rotated 90 CW
            context.translateBy(x: width, y: 0)
            context.rotate(by: .pi / 2)
        case 7:  // mirrored horizontal, rotated 90 CW
            context.translateBy(x: width, y: height)
            context.rotate(by: -.pi / 2)
            context.scaleBy(x: 1, y: -1)
        case 8:  // rotated 270 CW
            context.translateBy(x: 0, y: height)
            context.rotate(by: -.pi / 2)
        default:
            break
        }
    }

    /// Read the source's compressed bytes. The `.fileURL` arm reads at most
    /// `maxBytes + 1`, so an over-cap file is detected without buffering the whole
    /// bomb; the `.data` arm's bound is necessarily the CALLER's — the bytes are
    /// already resident (the ios-dts.3 importer must apply its own bounded read
    /// before constructing `.data`). `nil` only when the source could not be read
    /// at all; an empty file reads as empty bytes (folding to `notAnImage`, like an
    /// empty `.data`).
    private static func boundedBytes(_ source: ImageDecodeSource, maxBytes: Int) -> Data? {
        switch source {
        case .data(let data):
            return data
        case .fileURL(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            do {
                return try handle.read(upToCount: maxBytes + 1) ?? Data()
            } catch {
                return nil
            }
        }
    }
}

/// Container half of the header gate (judged before the metadata read).
func containerRejection(type: UTType?, config: ImageDecodeConfig) -> ImageDecodeRejectedKind? {
    guard let type, config.allowedContentTypes.contains(where: { type.conforms(to: $0) })
    else { return .notAnImage }
    return nil
}

/// Dimension half of the header gate, pure so cap trips are testable without giant
/// fixtures (Android `headerRejection` mirror). Per-side precedes area — an
/// ordering that is load-bearing beyond semantics: with both sides bounded at
/// `maxDimensionPx`, the area multiply cannot overflow `Int`.
func dimensionRejection(
    width: Int, height: Int, config: ImageDecodeConfig
) -> ImageDecodeRejectedKind? {
    if width > config.maxDimensionPx || height > config.maxDimensionPx {
        return .dimensionsTooLarge
    }
    if width * height > config.maxAreaPx {
        return .dimensionsTooLarge
    }
    return nil
}

/// Mirror of Android `isOutputSizeValid` INCLUDING its overflow widening: positive
/// bounds whose product sits within the output-pixel ceiling; an overflowing
/// product is invalid, never a trap (this guard's whole job is rejecting the
/// caller bug, not crashing on it).
func isOutputSizeValid(maxWidthPx: Int, maxHeightPx: Int, maxOutputPixels: Int) -> Bool {
    guard maxWidthPx > 0, maxHeightPx > 0 else { return false }
    let (product, overflowed) = maxWidthPx.multipliedReportingOverflow(by: maxHeightPx)
    return !overflowed && product <= maxOutputPixels
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
