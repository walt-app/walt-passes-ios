import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import CoreGraphics
import CoreImage

@testable import PassesUI

@Suite("BoundedImage decoder")
struct BoundedImageDecoderTests {

    /// Synthesize a PNG of the given pixel dimensions backed by ImageIO so the
    /// test does not need a fixture file.
    private func pngBytes(width: Int, height: Int) -> Data {
        let context = CIContext()
        let filter = CIFilter(name: "CIConstantColorGenerator")!
        filter.setValue(CIColor(red: 0.5, green: 0.5, blue: 0.5), forKey: "inputColor")
        let cropped = filter.outputImage!.cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let cgImage = context.createCGImage(cropped, from: cropped.extent)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func acceptsImageWithinBounds() {
        let bytes = pngBytes(width: 64, height: 64)
        let (image, reason) = decodeBoundedImage(rawBytes: bytes, bounds: .default)
        #expect(reason == nil)
        #expect(image != nil)
    }

    @Test func rejectsExceedsWidth() {
        let bytes = pngBytes(width: 128, height: 64)
        let tight = ImageRenderBounds(maxWidthPx: 64, maxHeightPx: 256, maxAreaPx: 1_000_000)
        let (image, reason) = decodeBoundedImage(rawBytes: bytes, bounds: tight)
        #expect(reason == .exceedsWidth)
        #expect(image == nil)
    }

    @Test func rejectsExceedsHeight() {
        let bytes = pngBytes(width: 64, height: 128)
        let tight = ImageRenderBounds(maxWidthPx: 256, maxHeightPx: 64, maxAreaPx: 1_000_000)
        let (image, reason) = decodeBoundedImage(rawBytes: bytes, bounds: tight)
        #expect(reason == .exceedsHeight)
        #expect(image == nil)
    }

    @Test func rejectsExceedsArea() {
        let bytes = pngBytes(width: 100, height: 100)
        let tight = ImageRenderBounds(maxWidthPx: 256, maxHeightPx: 256, maxAreaPx: 5_000)
        let (image, reason) = decodeBoundedImage(rawBytes: bytes, bounds: tight)
        #expect(reason == .exceedsArea)
        #expect(image == nil)
    }

    @Test func rejectsMalformedBytes() {
        let bytes = Data([0x00, 0x01, 0x02, 0x03])
        let (image, reason) = decodeBoundedImage(rawBytes: bytes, bounds: .default)
        #expect(reason == .malformed)
        #expect(image == nil)
    }
}
