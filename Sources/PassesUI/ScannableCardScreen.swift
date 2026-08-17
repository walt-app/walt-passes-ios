import PassesCore
import PassesUICore
import SwiftUI

/// Full-screen surface for scanning a `ScannableCard`. Wraps `ScannableCardView`
/// with minimal chrome: user-controlled label (FSI/PDI isolated), barcode
/// rendered at its full nominal size on a content-sized white backing, and the
/// non-suppressible `ScannableCardTrustCaption` docked at the bottom (C2 in
/// SCANNABLE_CARD_THREAT_MODEL.md).
///
/// The white backing is sized to the code plus the quiet-zone margin, not to
/// the whole screen (wpass-1wu.2): the rest of the surface is transparent so
/// the host's background shows through. The card is fixed white rather than Android's
/// adaptive `colorScheme.surface`: the CoreImage raster bakes an opaque white
/// background, so an adaptive dark card would leave a white seam around the code
/// in dark mode. Content on the card is forced light-scheme so the payload
/// caption stays legible on white.
///
/// `faceTint` (wpass-80y.1 mirror) draws a card face behind the white code
/// panel and moves the label + payload readback onto it; the panel behind the
/// code stays `scanCodePanel` white — the tint can never reach it. The tint is
/// presentation only: the kernel never learns why a color was chosen and stores
/// nothing (which color an item carries is the consumer's `WalletColorRepository`;
/// `ScannableCard` deliberately carries no color field, wpass-q5p). Ink on the
/// face is derived from the tint's luminance via `inkOn` so an arbitrary
/// consumer tint stays legible in both themes — a contrast guarantee, not a
/// brand token. Pass an opaque color: ink is derived from the nominal value, so
/// a translucent tint composites over host paint the kernel cannot see. `nil`
/// (and a fully transparent tint, via `faceIsTinted`) keeps today's surface, so
/// every existing caller is unchanged.
///
/// `showLabel` gates ONLY the label `Text` (wpass-1wu.1); neither it nor
/// `faceTint` can suppress the barcode, the payload caption, or the trust
/// caption.
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardScreen`.
public struct ScannableCardScreen: View {
    let card: ScannableCard
    let showLabel: Bool
    let trustCaption: TrustCaptionPlacement
    let faceTint: ArgbColor?

    /// `trustCaption` selects how the provenance signal is carried: `.docked`
    /// (default) composes the verbatim caption at the bottom; `.hostedTypeRow`
    /// renders no kernel caption because the host carries the claim via its own
    /// "Pass type" row — the audited C2 concession (see `TrustCaptionPlacement`
    /// and SCANNABLE_CARD_THREAT_MODEL.md).
    public init(
        card: ScannableCard,
        showLabel: Bool = true,
        trustCaption: TrustCaptionPlacement = .docked,
        faceTint: ArgbColor? = nil
    ) {
        self.card = card
        self.showLabel = showLabel
        self.trustCaption = trustCaption
        self.faceTint = faceTint
    }

    public var body: some View {
        VStack(spacing: 0) {
            if faceIsTinted(faceTint), let faceTint {
                tintedCodeCard(faceTint)
                    .padding(Self.screenMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                untintedBody
            }
            if rendersKernelCaption {
                ScannableCardTrustCaption()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Today's surface, kept verbatim for every pre-tint caller: label above,
    /// code + payload caption on the white backing.
    @ViewBuilder
    private var untintedBody: some View {
        if showLabel {
            Text(isolated(card.label))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, Self.screenMargin)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
        // The detail surface is the one place large enough for the POS-scan payload
        // caption (GH #102); opting in means the view manages its own a11y (image
        // hidden, caption announced), so no blanket accessibilityHidden here.
        ScannableCardView(card: card, showPayloadCaption: true)
            .padding(Self.codeQuietZone)
            .background(Self.scanCodePanel, in: RoundedRectangle(cornerRadius: Self.panelRadius))
            .environment(\.colorScheme, .light)
            .padding(Self.screenMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The tinted card (Android `CodeCard`): tinted face, white code panel,
    /// then label and payload readback ON the face in luminance-derived ink.
    private func tintedCodeCard(_ tint: ArgbColor) -> some View {
        let ink = inkOn(tint)
        return VStack(spacing: Self.panelToTextGap) {
            // The label and payload below announce this card; announcing the
            // code image too would read the label twice.
            ScannableCardView(card: card, showPayloadCaption: false)
                .accessibilityHidden(true)
                .padding(Self.codeQuietZone)
                .background(
                    Self.scanCodePanel, in: RoundedRectangle(cornerRadius: Self.panelRadius)
                )
                .environment(\.colorScheme, .light)
            VStack(spacing: Self.labelToPayloadGap) {
                if showLabel {
                    Text(isolated(card.label))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                // POS-scan fallback (GH #102) on the face, not the code panel,
                // so the panel stays a pure scan target. Full ink on a tint:
                // the flip's worst case leaves no headroom for alpha.
                Text(isolated(card.payload))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(Self.cardPadding)
        .background(tint.swiftUIColor, in: RoundedRectangle(cornerRadius: Self.cardRadius))
    }

    /// Exhaustive over the placement (mirror of Android's `when`): a future
    /// placement case forces a compile-time decision here instead of silently
    /// omitting the caption — the wrong failure direction on a trust surface.
    var rendersKernelCaption: Bool {
        switch trustCaption {
        case .docked: return true
        case .hostedTypeRow: return false
        }
    }

    /// White-card padding around the code. Unlike Android's ZXing, CoreImage
    /// bakes little margin into the raster, so on iOS this white margin doubles
    /// as the scan quiet zone as well as visual breathing room.
    static let codeQuietZone: CGFloat = 16

    /// Literally white, never a theme token and never the face tint: the code
    /// is real content and must stay theme-independent and scannable in dark
    /// mode. Rerouting the panel off this constant, or letting a tint reach it,
    /// is amending the contract rather than refactoring it.
    static let scanCodePanel = Color.white

    // Tinted-face registers (26.08.08 design card anatomy; wpass-80y.1).
    static let screenMargin: CGFloat = 24
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 18
    static let panelRadius: CGFloat = 16
    static let panelToTextGap: CGFloat = 16
    static let labelToPayloadGap: CGFloat = 4
}

/// Contrast-derived ink for text sitting on the tinted face. Consumers may pass
/// any tint, so the flip keeps the label and payload legible rather than
/// assuming a light palette. Neutral black/white by design: `PassesUI` carries
/// no brand values. Internal so a test can pin the guarantee across the tint
/// range rather than at whichever swatches a smoke test picks.
func inkOn(_ tint: ArgbColor) -> Color {
    relativeLuminance(tint) > inkFlipLuminance ? .black : .white
}

/// WCAG relative luminance of the tint's nominal (alpha-ignored) sRGB value.
private func relativeLuminance(_ color: ArgbColor) -> Double {
    func channel(_ value: UInt8) -> Double {
        let c = Double(value) / 255.0
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red) + 0.7152 * channel(color.green)
        + 0.0722 * channel(color.blue)
}

/// Where black and white ink tie on WCAG contrast: black scores `(L + 0.05) / 0.05`
/// and white `1.05 / (L + 0.05)`, which cross at `L = sqrt(0.0525) - 0.05 ≈ 0.179`.
/// Flipping at the intuitive 0.5 would hand every mid-tone tint the WORSE of the
/// two inks. The tie point is also the worst case: no tint scores below ~4.58:1
/// against the ink chosen here.
private let inkFlipLuminance = 0.179
