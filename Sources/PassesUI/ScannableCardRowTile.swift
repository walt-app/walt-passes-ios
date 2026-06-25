import PassesCore
import PassesUICore
import SwiftUI

/// Wallet-row register for a `ScannableCard`. Sibling to `ScannableCardTile`;
/// intended for consumers that interleave scannable cards with passes / PDFs in
/// a single homogeneous list rather than presenting them in their own carousel
/// lane.
///
/// The trust caption shifts from list-row to detail-surface only; the bottom-
/// docked `ScannableCardTrustCaption` on `ScannableCardScreen` retains the C2
/// guarantee a user who taps the row to use the artifact still sees "Created by
/// you" before scanning.
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardRowTile`.
public struct ScannableCardRowTile<LeadingSlot: View>: View {
    let card: ScannableCard
    let onTap: () -> Void
    let leadingSlot: () -> LeadingSlot
    @Environment(\.passesSemantics) private var semantics

    public init(
        card: ScannableCard,
        onTap: @escaping () -> Void,
        @ViewBuilder leadingSlot: @escaping () -> LeadingSlot
    ) {
        self.card = card
        self.onTap = onTap
        self.leadingSlot = leadingSlot
    }

    public var body: some View {
        let accent = (semantics?.unverifiedArtifact ?? .placeholder).accent.swiftUIColor
        let labelText = isolated(card.label)
        let formatToken = card.format.rowSubtitle
        Button(action: onTap) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 4)
                leadingSlot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(labelText)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(formatToken)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                Spacer()
            }
            .frame(minHeight: 64)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(labelText), \(formatToken), barcode card"))
    }
}

extension ScannableCardRowTile where LeadingSlot == EmptyView {
    public init(card: ScannableCard, onTap: @escaping () -> Void) {
        self.init(card: card, onTap: onTap, leadingSlot: { EmptyView() })
    }
}

extension ScannableFormat {
    fileprivate var rowSubtitle: String {
        switch self {
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .ean13: return "EAN-13"
        case .upcA: return "UPC-A"
        case .qr: return "QR"
        }
    }
}
