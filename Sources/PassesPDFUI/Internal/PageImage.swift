#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import SwiftUI

/// Holds a decoded page bitmap and its source-page aspect ratio. The image
/// shape (`CGImage`) is the iOS analogue of Android's `Bitmap` /
/// `ImageBitmap`: an immutable pixel container that `SwiftUI.Image` can
/// draw without copying. Sendable so it can cross the actor boundary into
/// `@MainActor` view state. `CGImage` is reference-typed but is documented
/// as safe to share across threads after creation, so the `@unchecked`
/// conformance reflects what the platform already guarantees.
struct PageImage: @unchecked Sendable {
    let cgImage: CGImage
    let pageAspect: Float

    var image: Image {
        Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

/// Decode a pixel buffer (RGBA8, row-major, no padding) into a `PageImage`.
/// The buffer shape mirrors what `PDFKitRenderer.rasterise` produces.
/// Returns `nil` if the buffer cannot be wrapped into a `CGImage`.
func decodePageImage(from decoded: DecodedPage) -> PageImage? {
    let bytesPerPixel = 4
    let bytesPerRow = decoded.widthPx * bytesPerPixel
    let expectedSize = bytesPerRow * decoded.heightPx
    guard decoded.pixels.count == expectedSize else { return nil }

    let provider = decoded.pixels.withUnsafeBytes { raw -> CGDataProvider? in
        guard let base = raw.baseAddress else { return nil }
        let copy = CFDataCreate(
            kCFAllocatorDefault,
            base.assumingMemoryBound(to: UInt8.self),
            decoded.pixels.count
        )
        guard let copy else { return nil }
        return CGDataProvider(data: copy)
    }
    guard let provider else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    guard let cgImage = CGImage(
        width: decoded.widthPx,
        height: decoded.heightPx,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else {
        return nil
    }
    return PageImage(cgImage: cgImage, pageAspect: decoded.pageAspect)
}
#endif
