import PassesUICore
import SwiftUI
import Testing

@testable import PassesUI

/// Pins the faceTint contract on `ScannableCardScreen` (wpass-80y.1/.5 mirror):
/// ink is derived from the tint's luminance flipping at the WCAG black/white
/// tie point (not 0.5), the worst case still clears AA-adjacent contrast, and
/// the code panel stays literally white — a tint may never reach it.
struct ScannableCardFaceTintTests {

    @Test func inkFlipsAtTheWcagTiePointNotAtHalf() {
        // Black and white ink tie at L = sqrt(0.0525) - 0.05 (about 0.179).
        // Flipping at 0.5 would hand mid-tones the WORSE ink: #2E8B7F has
        // L of about 0.206, where black scores 5.1:1 over white's 4.1:1.
        #expect(inkOn(ArgbColor(argb: 0xFF2E_8B7F)) == .black)
        // Well below the tie point stays white ink.
        #expect(inkOn(ArgbColor(argb: 0xFF1E_1E1E)) == .white)
        // Well above stays black ink.
        #expect(inkOn(ArgbColor(argb: 0xFFFB_DDC3)) == .black)
    }

    @Test func chosenInkClearsTheWorstCaseContrastOnEveryGrey() {
        // The tie point is also the worst case: no tint scores below ~4.58:1
        // against the ink chosen for it. Sweep the grey axis to pin that the
        // flip never picks the losing ink.
        for value in 0...255 {
            let channel = UInt32(value)
            let tint = ArgbColor(argb: 0xFF00_0000 | channel << 16 | channel << 8 | channel)
            let ink: ArgbColor =
                inkOn(tint) == .black
                ? ArgbColor(argb: 0xFF00_0000) : ArgbColor(argb: 0xFFFF_FFFF)
            #expect(contrastRatio(tint, ink) >= 4.5, "grey \(value) fell below AA")
        }
    }

    @Test func codePanelStaysLiterallyWhite() {
        // Literally white, never a theme token and never the face tint: the
        // code is real content and must stay scannable in dark mode. Rerouting
        // the panel off this constant is amending the contract.
        #expect(ScannableCardScreen.scanCodePanel == Color.white)
    }

    @Test func tintedFaceMetricsMatchTheFigmaRegister() {
        #expect(ScannableCardScreen.cardRadius == 20)
        #expect(ScannableCardScreen.cardPadding == 18)
        #expect(ScannableCardScreen.panelRadius == 16)
        #expect(ScannableCardScreen.panelToTextGap == 16)
        #expect(ScannableCardScreen.labelToPayloadGap == 4)
        #expect(ScannableCardScreen.screenMargin == 24)
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
