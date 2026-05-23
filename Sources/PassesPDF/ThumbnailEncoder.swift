import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Reconstructs a bitmap from a ``RenderResult/ok(pixels:widthPx:heightPx:pageAspect:)``
/// pixel buffer and encodes it as PNG bytes for the storage thumbnail blob.
///
/// Mirrors Android's `ThumbnailEncoder` seam. Lifted to an internal protocol
/// so unit tests can plug in a deterministic fake. The production
/// ``PNGThumbnailEncoder`` does the real CoreGraphics path.
package protocol ThumbnailEncoder: Sendable {
    func encode(render: RenderResult) throws -> Data
}

package struct ThumbnailEncoderError: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
package struct PNGThumbnailEncoder: ThumbnailEncoder {
    package init() {}

    package func encode(render: RenderResult) throws -> Data {
        guard case let .ok(pixels, widthPx, heightPx, _) = render else {
            throw ThumbnailEncoderError("encode requires a .ok render result")
        }
        let bytesPerPixel = 4
        let bytesPerRow = widthPx * bytesPerPixel
        guard pixels.count == bytesPerRow * heightPx else {
            throw ThumbnailEncoderError("pixel buffer size does not match dimensions")
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw ThumbnailEncoderError("CGDataProvider creation failed")
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ThumbnailEncoderError("CGImage creation failed")
        }
        let dest = CFDataCreateMutable(nil, 0)!
        let pngType: CFString
        if #available(iOS 14, macOS 11, *) {
            pngType = UTType.png.identifier as CFString
        } else {
            pngType = "public.png" as CFString
        }
        guard let writer = CGImageDestinationCreateWithData(dest, pngType, 1, nil) else {
            throw ThumbnailEncoderError("CGImageDestination creation failed")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw ThumbnailEncoderError("PNG finalize failed")
        }
        return dest as Data
    }
}
#endif
