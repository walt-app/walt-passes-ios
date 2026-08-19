import PassesUICore
import SwiftUI
import Testing

@testable import PassesUI

/// Pins the faceTint contract on `ScannableCardScreen` (wpass-80y.1/.5 mirror):
/// the body's paint decision routes through the shared gate in BOTH directions,
/// ink flips at the WCAG tie point (see `inkFlipLuminance`'s doc for the math),
/// the worst case still clears AA-adjacent contrast, and the code panel stays
/// literally white — a tint may never reach it.
@MainActor
struct ScannableCardFaceTintTests {

    @Test func facePaintTakesAnOpaqueTintWithItsDerivedInk() {
        // Pinning only the fallback would leave "ignores faceTint entirely"
        // green — the wpass-80y.5 lesson, so both directions are pinned.
        let teal = ArgbColor(argb: 0xFF00_837E)
        let paint = ScannableCardScreen.facePaint(teal)
        #expect(paint != nil)
        #expect(paint?.face == teal.swiftUIColor)
        #expect(paint?.ink == inkOn(teal))
    }

    @Test func facePaintFallsBackForNilAndTransparentTints() {
        #expect(ScannableCardScreen.facePaint(nil) == nil)
        // Transparent-but-specified is the exact wpass-80y.5 bug: painting it
        // would derive ink from luminance 0 over host paint.
        #expect(ScannableCardScreen.facePaint(ArgbColor(argb: 0x00FF_D8D5)) == nil)
    }

    @Test func inkFlipsAtTheWcagTiePointNotAtHalf() {
        // Android's recorded example: #2E8B7F (L ≈ 0.206) takes black at 5.1:1
        // where a 0.5 flip would hand it white at 4.1:1.
        #expect(inkOn(ArgbColor(argb: 0xFF2E_8B7F)) == .black)
        #expect(inkOn(ArgbColor(argb: 0xFF1E_1E1E)) == .white)
        #expect(inkOn(ArgbColor(argb: 0xFFFB_DDC3)) == .black)
    }

    @Test func chosenInkClearsTheWorstCaseContrastOnEveryGrey() {
        // The tie point is also the worst case: no tint scores below ~4.58:1
        // against the ink chosen for it. The grey axis suffices because inkOn
        // depends on luminance alone and greys realize every luminance.
        for value in 0...255 {
            let channel = UInt32(value)
            let tint = ArgbColor(argb: 0xFF00_0000 | channel << 16 | channel << 8 | channel)
            let ink: ArgbColor =
                inkOn(tint) == .black
                ? ArgbColor(argb: 0xFF00_0000) : ArgbColor(argb: 0xFFFF_FFFF)
            #expect(contrastRatio(tint, ink) >= 4.5, "grey \(value) fell below AA")
        }
    }

    @Test func codePanelStaysLiterallyWhiteWithItsQuietZone() {
        // The scannability contract (see `scanCodePanel`'s doc): rerouting the
        // panel off this constant, or letting a tint reach it, is amending the
        // contract rather than refactoring it.
        #expect(ScannableCardScreen.scanCodePanel == Color.white)
        #expect(ScannableCardScreen.codeQuietZone == 16)
    }

    // WCAG math, local to the test so the pin cannot share a bug with the
    // production derivation it checks.
    private func contrastRatio(_ a: ArgbColor, _ b: ArgbColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ color: ArgbColor) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }
}
