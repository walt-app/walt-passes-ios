import Testing

@testable import PassesPDFUI

/// Pinning the request-dimension clamp math used by
/// `FullScreenDocumentView` so the renderer is never asked to allocate
/// beyond the 4 MP cap (ADR 0005 D7). The math itself is the iOS
/// equivalent of Android's `clampToMaxPixels` inside
/// `FullScreenDocumentView.kt`.
@Suite("clampToMaxPixels")
struct FullScreenDimensionClampTests {

    @Test func dimensionsUnderCapPassThrough() {
        let dims = clampToMaxPixels(widthPx: 1000, heightPx: 1000, maxPixels: 4 * 1024 * 1024)
        #expect(dims.widthPx == 1000)
        #expect(dims.heightPx == 1000)
    }

    @Test func dimensionsAtCapPassThrough() {
        let dims = clampToMaxPixels(widthPx: 2048, heightPx: 2048, maxPixels: 4 * 1024 * 1024)
        #expect(dims.widthPx == 2048)
        #expect(dims.heightPx == 2048)
    }

    @Test func dimensionsOverCapAreScaledDownPreservingAspect() {
        // 4096 * 4096 = 16,777,216 = 4 * (4*1024*1024). Clamp halves
        // each side to land at the cap.
        let dims = clampToMaxPixels(widthPx: 4096, heightPx: 4096, maxPixels: 4 * 1024 * 1024)
        #expect(dims.widthPx == 2048)
        #expect(dims.heightPx == 2048)
    }

    @Test func nonSquareDimensionsClampWhilePreservingAspectRatio() {
        let dims = clampToMaxPixels(widthPx: 8000, heightPx: 4000, maxPixels: 4 * 1024 * 1024)
        // Aspect 2:1; under cap.
        #expect(Double(dims.widthPx) / Double(dims.heightPx) > 1.99)
        #expect(Double(dims.widthPx) / Double(dims.heightPx) < 2.01)
        #expect(Int64(dims.widthPx) * Int64(dims.heightPx) <= 4 * 1024 * 1024)
    }

    @Test func smallestPossibleDimensionsAreClampedAtOne() {
        // Extreme clamp does not produce zero-sized dimensions, even if
        // the requested aspect would mathematically scale to fractional
        // pixels less than one.
        let dims = clampToMaxPixels(widthPx: 100_000, heightPx: 1, maxPixels: 1024)
        #expect(dims.widthPx >= 1)
        #expect(dims.heightPx >= 1)
    }
}
