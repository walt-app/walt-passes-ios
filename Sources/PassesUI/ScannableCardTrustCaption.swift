import SwiftUI

/// Non-suppressible "Created by you" caption that anchors the trust contract of
/// every `ScannableCard` surface (C2 in SCANNABLE_CARD_THREAT_MODEL.md). Has no
/// theme token, no `enabled` parameter, and no overload that skips rendering it.
/// Mirror of Android's `ScannableCardTrustCaption`.
public struct ScannableCardTrustCaption: View {
    @Environment(\.passesSemantics) private var semantics

    public init() {}

    public var body: some View {
        let style = semantics?.unverifiedArtifact ?? .placeholder
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundColor(style.captionIconTint.swiftUIColor)
            Text(Self.captionText)
                .font(.caption.weight(.semibold))
                .foregroundColor(style.captionForeground.swiftUIColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.captionBackground.swiftUIColor)
    }

    /// The exact caption copy. Wording is the load-bearing part of
    /// SCANNABLE_CARD_THREAT_MODEL.md C2; a contributor changing this string is
    /// making a security-policy edit.
    public nonisolated static let captionText = "Created by you"
}
