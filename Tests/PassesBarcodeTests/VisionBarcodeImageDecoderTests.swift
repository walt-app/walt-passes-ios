import Foundation
import PassesCore
import Testing

@testable import PassesBarcode

/// Behavioural coverage for ``VisionBarcodeImageDecoder``: the roster round-trip (benign payloads
/// decode to the right format), the bounded-decode rejections, and the empty/unreadable paths.
/// The adversarial faithfulness corpus is its own suite, ``HostilePayloadFidelityTests``.
@Suite("VisionBarcodeImageDecoder")
struct VisionBarcodeImageDecoderTests {
    private let decoder = VisionBarcodeImageDecoder()

    @Test func decodesQrToQrFormat() async {
        let png = BarcodeImageFactory.qrPNG("WALT-MEMBER-12345")
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: "WALT-MEMBER-12345", format: .qr))
    }

    @Test func decodesCode128ToCode128Format() async {
        let png = BarcodeImageFactory.code128PNG("A1B2C3D4")
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: "A1B2C3D4", format: .code128))
    }

    @Test func blankImageHasNoBarcode() async {
        let png = BarcodeImageFactory.blankPNG(width: 400, height: 400)
        #expect(await decoder.decode(source: .data(png)) == .noBarcodeFound)
    }

    @Test func nonImageDataFailsDecode() async {
        let junk = Data("this is not an image".utf8)
        #expect(await decoder.decode(source: .data(junk)) == .decodeFailed(reason: .imageDecodeFailed))
    }

    @Test func missingFileIsSourceUnreadable() async {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        #expect(await decoder.decode(source: .fileURL(url)) == .decodeFailed(reason: .sourceUnreadable))
    }

    @Test func oversizeDataIsRejectedAsTooLarge() async {
        let config = BarcodeDecodeConfig(maxBytes: 1024)
        let png = BarcodeImageFactory.qrPNG("padding-past-the-tiny-byte-cap-padding-padding")
        #expect(png.count > 1024)
        let decoder = VisionBarcodeImageDecoder(config: config)
        #expect(await decoder.decode(source: .data(png)) == .decodeFailed(reason: .imageTooLarge))
    }

    @Test func oversizeDimensionsAreRejectedBeforeAllocation() async {
        let config = BarcodeDecodeConfig(maxDimensionPx: 100)
        let png = BarcodeImageFactory.blankPNG(width: 400, height: 400)
        let decoder = VisionBarcodeImageDecoder(config: config)
        #expect(await decoder.decode(source: .data(png)) == .decodeFailed(reason: .imageTooLarge))
    }

    @Test func oversizeAreaIsRejectedBeforeAllocation() async {
        // Both sides under the per-side cap, product over the megapixel cap.
        let config = BarcodeDecodeConfig(maxDimensionPx: 1000, maxAreaPx: 10_000)
        let png = BarcodeImageFactory.blankPNG(width: 400, height: 400)
        let decoder = VisionBarcodeImageDecoder(config: config)
        #expect(await decoder.decode(source: .data(png)) == .decodeFailed(reason: .imageTooLarge))
    }

    @Test func fileURLSourceDecodes() async throws {
        let png = BarcodeImageFactory.qrPNG("FROM-FILE-URL")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await decoder.decode(source: .fileURL(url)) == .decodedBarcode(payload: "FROM-FILE-URL", format: .qr))
    }
}
