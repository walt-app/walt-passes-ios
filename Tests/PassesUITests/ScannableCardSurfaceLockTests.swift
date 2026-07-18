import PassesCore
import SwiftUI
import Testing

@testable import PassesUI

/// Pins the parameter-shape discipline of the scannable-card surfaces. Mirror of
/// Android's `ComposableSurfaceLockTest` (scannable-card half).
///
/// Java reflection lets the Android test count parameters via the
/// Compose-compiler-mangled JVM signatures. Swift has no equivalent reflection
/// over function signatures; the iOS analogue is to construct each view through
/// its single declared initialiser with every public parameter, so any
/// added/removed/renamed parameter fails to compile.
@MainActor
@Suite("ScannableCard surface lock")
struct ScannableCardSurfaceLockTests {

    private static func fixture() -> ScannableCard? {
        let result = ScannableCardInputValidator.validate(
            input: ScannableCardCreateInput(payload: "QR payload", format: .qr, label: "Loyalty"),
            id: ScannableCardId("card-1"),
            createdAt: PassInstant(epochMillis: 0)
        )
        guard case .success(let card) = result else { return nil }
        return card
    }

    @Test func trustCaptionExposesOnlyTheZeroArityInitialiser() {
        // C2 in SCANNABLE_CARD_THREAT_MODEL.md: no `enabled`, no theme
        // suppression flag, no overload that hides the caption.
        _ = ScannableCardTrustCaption()
    }

    @Test func screenExposesExactlyTwoPublicInitialiserParameters() {
        // (card, showLabel). `showLabel` (wpass-1wu.1) gates ONLY the top label
        // Text so a host rendering its own title avoids a duplicate; it cannot
        // omit the barcode, the payload caption, or the bottom-docked
        // non-suppressible ScannableCardTrustCaption (C2). Android counts three
        // (the extra is `modifier`). Adding a parameter that could hide the
        // trust caption would breach C2; review the threat model before
        // changing this initialiser.
        guard let card = Self.fixture() else {
            Issue.record("validator should accept fixture input")
            return
        }
        _ = ScannableCardScreen(card: card, showLabel: false)
    }

    @Test func screenQuietZoneIsVisualSixteenPoints() {
        // The scan quiet zone is baked into the raster; this margin is the
        // white card's visual breathing room (wpass-1wu.2).
        #expect(ScannableCardScreen.codeQuietZone == 16)
    }
}
