import Foundation
import Testing

@testable import PassesCore

@Suite("PngDimensions")
struct PngDimensionsTests {

    @Test func readsValidIhdr() {
        let dim = readPngDimensions(pngBytes(width: 100, height: 50))
        #expect(dim == PngDimensions(width: 100, height: 50))
    }

    @Test func nonPngReturnsNil() {
        #expect(readPngDimensions([0x00, 0x01, 0x02, 0x03]) == nil)
    }

    @Test func truncatedReturnsNil() {
        #expect(readPngDimensions([0x89, 0x50, 0x4E, 0x47]) == nil)
    }

    @Test func zeroDimensionReturnsNil() {
        #expect(readPngDimensions(pngBytes(width: 0, height: 10)) == nil)
    }

    @Test func highBitWidthTreatedAsLargePositive() {
        // 0x80000000 has the high bit set; widened to Int64 it must stay positive (not negate).
        let dim = readPngDimensions(pngBytes(width: 0x8000_0000, height: 1))
        #expect(dim?.width == 0x8000_0000)
    }

    @Test func imagePixelCapTripsInPipeline() {
        // A 4096x4096 default cap; a 5000x5000 image exceeds it.
        let payload = [
            ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson()),
            ZipBuilder.File("background.png", pngBytes(width: 5000, height: 5000)),
        ]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let parser = PassParserFactory.create()
        let result = parser.parse(source: .bytes(Data(archive)))
        #expect(result == .malformed(reason: .resourceLimitExceeded(limit: .imagePixelCount)))
    }
}
