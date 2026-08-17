import Testing

@testable import PassesCore
@testable import PassesUI

/// Pins the detail-surface failure routing that `BarcodeRenderer` keeps after delegating
/// to `PassesCore.BarcodeEncoder` (ios-pjs.19): a failed 1D encode degrades to the grey
/// placeholder so the surface composes, while a failed QR / Code128 encode returns nil
/// (the "failed to render" tile). The split is load-bearing — a grey blob on a detail
/// surface must never be mistaken for the compact path's nil-only contract, and
/// `CompactCodeViewTests` pins that side.
@Suite("BarcodeRenderer failure routing")
struct BarcodeRendererFailureRoutingTests {

    @Test @MainActor func oneDimensionalFailuresDegradeToThePlaceholder() {
        // Bad EAN-13 check digit and a lowercase Code39 payload both fail the encoder's
        // structural re-check; the detail path must still hand back a paintable image.
        #expect(BarcodeRenderer.cgImage(payload: "4006381333930", format: .ean13) != nil)
        #expect(BarcodeRenderer.cgImage(payload: "lowercase", format: .code39) != nil)
    }

    @Test @MainActor func coreImageFailuresReturnNilForTheFailureTile() {
        // The uniform empty-payload refusal is the reachable failure for QR/Code128.
        #expect(BarcodeRenderer.cgImage(payload: "", format: .qr) == nil)
        #expect(BarcodeRenderer.cgImage(payload: "", format: .code128) == nil)
    }
}
