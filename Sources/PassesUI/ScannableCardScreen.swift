import SwiftUI
import PassesCore
import PassesUICore

/// Full-screen surface for scanning a `ScannableCard`. Wraps `ScannableCardView`
/// with minimal chrome: user-controlled label up top (FSI/PDI isolated), barcode
/// rendered at its full nominal size, and the non-suppressible
/// `ScannableCardTrustCaption` docked at the bottom (C2 in
/// SCANNABLE_CARD_THREAT_MODEL.md).
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardScreen`.
public struct ScannableCardScreen: View {
    let card: ScannableCard

    public init(card: ScannableCard) {
        self.card = card
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(isolated(card.label))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            // The detail surface is the one place large enough for the POS-scan payload
            // caption (GH #102); opting in means the view manages its own a11y (image
            // hidden, caption announced), so no blanket accessibilityHidden here.
            ScannableCardView(card: card, showPayloadCaption: true)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScannableCardTrustCaption()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
