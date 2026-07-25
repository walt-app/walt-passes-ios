import PassesCore
import SwiftUI
import Testing

@testable import PassesUI

/// Pins the compact-render contracts that matter at list scale (ipass-65p.1),
/// mirroring Android's `CompactCodeViewTest` (wpass-tjc.2):
///
///  1. A valid `(payload, format)` pair produces a real raster through the
///     kernel encoder, and the view constructs with and without a caller
///     description.
///  2. The white backing is literally white, never a theme token — the
///     dark-mode scannability guarantee.
///  3. Symbologies without a native encoder route to the failure tile (nil),
///     never the detail surfaces' grey placeholder — a list face must not show
///     a grey blob that could be mistaken for a real code.
@Suite("Compact code view")
struct CompactCodeViewTests {

    @MainActor
    @Test func validQrConstructsWithCallerDescription() {
        let view = CompactCodeView(
            payload: "LOCKER-0042",
            format: .qr,
            contentDescription: "Locker code, QR code"
        )
        #expect(type(of: view.body) != Never.self)
    }

    @MainActor
    @Test func validCode128ConstructsWithoutDescription() {
        let view = CompactCodeView(payload: "21000456782", format: .code128)
        #expect(type(of: view.body) != Never.self)
    }

    @Test func backingIsLiterallyWhiteNotAThemeToken() {
        // A refactor to a theme surface token must fail here, not in the field.
        #expect(compactCodeBacking == Color.white)
    }

    @Test func validPayloadsRenderThroughTheKernelEncoder() {
        #expect(CompactCodeView.renderImage(payload: "LOCKER-0042", format: .qr) != nil)
        #expect(CompactCodeView.renderImage(payload: "21000456782", format: .code128) != nil)
    }

    @Test func unsupportedSymbologiesRouteToFailureTileNotPlaceholder() {
        // BarcodeRenderer surfaces a grey placeholder for these on detail
        // surfaces (ADR passes-ui-2); the compact path must return nil instead.
        #expect(CompactCodeView.renderImage(payload: "4006381333931", format: .ean13) == nil)
        #expect(CompactCodeView.renderImage(payload: "036000291452", format: .upcA) == nil)
        #expect(CompactCodeView.renderImage(payload: "WALT-1", format: .code39) == nil)
    }

    @Test func compactFloorsSitBelowGateDistanceMinimums() {
        #expect(ScannableFormat.qr.compactMinSize == (48, 48))
        for oneDimensional: ScannableFormat in [.code128, .ean13, .upcA, .code39] {
            #expect(oneDimensional.compactMinSize == (96, 32))
        }
        // The detail-surface minimums must stay untouched above the floors.
        #expect(ScannableFormat.qr.minRenderSize == (240, 240))
        #expect(ScannableFormat.code128.minRenderSize == (320, 96))
    }
}
