import CoreGraphics
import Foundation
import ImageIO
import PassesCore
import Testing
import UniformTypeIdentifiers

@testable import PassesBarcode

/// The correctness proof for ``OneDimensionalBarcodeEncoder``: every hand-rolled
/// symbology must round-trip through the PRODUCTION decode path (bounded image
/// decode + Vision, expanded roster) back to the exact payload and format. A
/// wrong table entry, parity slip, or guard error makes Vision return nothing
/// or the wrong string — this suite is why the tables need no golden strings.
@Suite("OneD encode -> Vision decode round-trip")
struct OneDRoundTripTests {
    private let decoder = VisionBarcodeImageDecoder()

    @Test func ean13RoundTrips() async throws {
        let png = try pngFor(payload: "4006381333931", format: .ean13)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: "4006381333931", format: .ean13))
    }

    @Test func upcARoundTripsAndFoldsBackToTwelveDigits() async throws {
        // Vision reports UPC-A as EAN-13 with a leading zero; the roster fold
        // must undo that so the decoded card matches what was encoded.
        let png = try pngFor(payload: "036000291452", format: .upcA)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: "036000291452", format: .upcA))
    }

    @Test func code39RoundTrips() async throws {
        let png = try pngFor(payload: "HELLO-123", format: .code39)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: "HELLO-123", format: .code39))
    }

    @Test func code39FullAlphabetRoundTrips() async throws {
        // One payload touching every table entry: any single wrong encoding
        // corrupts the whole read.
        let alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%"
        let png = try pngFor(payload: alphabet, format: .code39, scale: 4)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: alphabet, format: .code39))
    }

    /// Rasterize the encoder's module row into a generously upscaled PNG, the
    /// same nearest-neighbor expansion the production renderer performs.
    private func pngFor(
        payload: String, format: ScannableFormat, scale: Int = 6
    ) throws -> Data {
        let matrix = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: payload, format: format))
        let width = matrix.width * scale
        let height = 160
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for x in 0..<matrix.width where matrix.isSet(x: x, y: 0) {
            context.fill(CGRect(x: x * scale, y: 0, width: scale, height: height))
        }
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
