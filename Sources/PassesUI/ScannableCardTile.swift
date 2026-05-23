import SwiftUI
import PassesCore
import PassesUICore

/// Home-lane tile for a `ScannableCard`. Renders four redundant artifact-class
/// distinguishers (dashed outline, leading accent band, smaller corner radius,
/// non-suppressible "Created by you" caption) per SCANNABLE_CARD_THREAT_MODEL.md
/// C1 / C2 so theming any single dimension flat cannot collapse the
/// verified/unverified distinction.
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardTile`.
public struct ScannableCardTile: View {
    let card: ScannableCard
    let onTap: () -> Void
    @Environment(\.passesSemantics) private var semantics

    public init(card: ScannableCard, onTap: @escaping () -> Void) {
        self.card = card
        self.onTap = onTap
    }

    public var body: some View {
        let style = semantics?.unverifiedArtifact ?? .placeholder
        let accent = style.accent.swiftUIColor
        Button(action: onTap) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        let (w, h) = card.format.previewSize
                        ScannableCardView(card: card)
                            .frame(width: w, height: h)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                    Text(isolated(card.label))
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ScannableCardTrustCaption()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            }
        }
        .buttonStyle(.plain)
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color(.sRGB, white: 0.97, opacity: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension ScannableFormat {
    fileprivate var previewSize: (CGFloat, CGFloat) {
        switch self {
        case .qr: return (96, 96)
        case .code128, .ean13, .upcA, .code39: return (132, 40)
        }
    }
}
