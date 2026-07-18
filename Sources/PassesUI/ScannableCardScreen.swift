import PassesCore
import PassesUICore
import SwiftUI

/// Full-screen surface for scanning a `ScannableCard`. Wraps `ScannableCardView`
/// with minimal chrome: user-controlled label up top (FSI/PDI isolated), barcode
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
/// `showLabel` gates ONLY the top label `Text` (wpass-1wu.1); it cannot suppress
/// the barcode, the payload caption, or the trust caption. Hosts that render
/// their own (editable) title above this surface pass `false` to drop the
/// duplicate. Default `true` keeps every existing caller unchanged.
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardScreen`.
public struct ScannableCardScreen: View {
    let card: ScannableCard
    let showLabel: Bool

    public init(card: ScannableCard, showLabel: Bool = true) {
        self.card = card
        self.showLabel = showLabel
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showLabel {
                Text(isolated(card.label))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            // The detail surface is the one place large enough for the POS-scan payload
            // caption (GH #102); opting in means the view manages its own a11y (image
            // hidden, caption announced), so no blanket accessibilityHidden here.
            ScannableCardView(card: card, showPayloadCaption: true)
                .padding(Self.codeQuietZone)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .environment(\.colorScheme, .light)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScannableCardTrustCaption()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// White-card padding around the code. Unlike Android's ZXing, CoreImage
    /// bakes little margin into the raster, so on iOS this white margin doubles
    /// as the scan quiet zone as well as visual breathing room.
    static let codeQuietZone: CGFloat = 16
}
