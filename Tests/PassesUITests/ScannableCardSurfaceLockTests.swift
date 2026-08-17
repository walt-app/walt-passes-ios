import PassesCore
import PassesUICore
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
        // suppression flag, no overload that hides the caption. The exact-arity
        // function reference fails to compile if ANY parameter is added, even a
        // defaulted one (a plain call would still compile through defaults).
        let lockedInit: () -> ScannableCardTrustCaption = ScannableCardTrustCaption.init
        _ = lockedInit()
    }

    @Test func screenExposesExactlyFourPublicInitialiserParameters() {
        // (card, showLabel, trustCaption, faceTint). `showLabel` (wpass-1wu.1)
        // gates ONLY the top label Text; `trustCaption` (wpass-gv6) is the ONE
        // audited way the kernel caption is omitted — `.hostedTypeRow` shifts
        // the C2 claim to the host's "Pass type" row, pinned consumer-side in
        // walt-ios. `faceTint` (wpass-80y.1) colors the card face only; it can
        // suppress neither the code, the payload readback, nor the caption.
        // Android counts five (the extra is `modifier`). The exact-arity
        // function reference fails to compile if any parameter is added,
        // removed, renamed, or retyped — even a defaulted addition, which a
        // plain call would let through; review the threat model before
        // changing this initialiser.
        let lockedInit: (ScannableCard, Bool, TrustCaptionPlacement, ArgbColor?) -> ScannableCardScreen =
            ScannableCardScreen.init(card:showLabel:trustCaption:faceTint:)
        _ = lockedInit
    }

    @Test func trustCaptionPlacementDefaultsToDocked() {
        guard let card = Self.fixture() else {
            Issue.record("validator should accept fixture input")
            return
        }
        // Omitting the argument keeps the docked caption, so every
        // pre-placement caller is unchanged.
        let screen = ScannableCardScreen(card: card)
        #expect(screen.trustCaption == .docked)
        #expect(screen.rendersKernelCaption)
    }

    @Test func hostedTypeRowOmitsTheKernelCaption() {
        guard let card = Self.fixture() else {
            Issue.record("validator should accept fixture input")
            return
        }
        // The body renders the caption iff this seam says so (the seam is the
        // exhaustive switch over the placement).
        let screen = ScannableCardScreen(card: card, trustCaption: .hostedTypeRow)
        #expect(!screen.rendersKernelCaption)
    }

    @Test func screenQuietZoneIsSixteenPoints() {
        // On iOS this white margin doubles as the scan quiet zone (CoreImage
        // bakes little margin into the raster) — shrinking it risks
        // scannability, not just looks (wpass-1wu.2).
        #expect(ScannableCardScreen.codeQuietZone == 16)
    }
}
