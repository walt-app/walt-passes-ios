import Testing

@testable import PassesCore
@testable import PassesUI

/// Pins the detail-surface render policy (ios-ra9). The bug this replaces:
/// 1D symbols were aspect-scaled with `.fill` inside a frame that set only
/// *minimums*, so a wide raster grew past its parent and dragged the whole
/// detail layout off-screen (wordmark and meta rows clipped at both edges) —
/// on device and simulator, for every 1D symbology.
@Suite("Code render policy")
struct CodeRenderPolicyTests {

    @Test func oneDimensionalSymbolsStretchToWidthSoTheyCannotOverflow() {
        // Width-bounded (`maxWidth: .infinity`) + fixed bar height is the only
        // policy that cannot exceed the parent. A regression to any
        // aspect-preserving mode reintroduces ios-ra9.
        for format: ScannableFormat in [.code128, .ean13, .upcA, .code39] {
            #expect(
                format.renderPolicy == .stretchToWidth(barHeight: 96),
                "\(format) must stretch to width, not preserve aspect")
        }
    }

    @Test func qrKeepsItsSquareFit() {
        // QR carries data on both axes, so it must never be stretched.
        #expect(ScannableFormat.qr.renderPolicy == .fitSquare(minSide: 240))
    }

    @Test func newTwoDimensionalArmsNeverStretch() {
        // Data rides both axes on both formats; the PDF417 floor is derived from the
        // writer's measured 2.7-3.5:1 aspect at the pinned EC (ios-pjs.16).
        #expect(ScannableFormat.aztec.renderPolicy == .fitSquare(minSide: 240))
        #expect(ScannableFormat.pdf417.renderPolicy == .fitToWidth(minHeight: 90))
    }

    @Test func policyStaysDerivedFromThePinnedGateDistanceSizes() {
        // renderPolicy reads minRenderSize so the scanability numbers have one
        // source of truth; this fails if the two drift apart.
        #expect(ScannableFormat.qr.renderPolicy == .fitSquare(minSide: ScannableFormat.qr.minRenderSize.0))
        #expect(
            ScannableFormat.code128.renderPolicy
                == .stretchToWidth(barHeight: ScannableFormat.code128.minRenderSize.1))
        #expect(
            ScannableFormat.aztec.renderPolicy
                == .fitSquare(minSide: ScannableFormat.aztec.minRenderSize.0))
        #expect(
            ScannableFormat.pdf417.renderPolicy
                == .fitToWidth(minHeight: ScannableFormat.pdf417.minRenderSize.1))
    }
}
