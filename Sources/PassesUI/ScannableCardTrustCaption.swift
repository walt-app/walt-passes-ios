import SwiftUI

/// Non-suppressible "Created by you" caption that anchors the trust contract of
/// every `ScannableCard` surface (C2 in SCANNABLE_CARD_THREAT_MODEL.md). Has no
/// theme token, no `enabled` parameter, and no overload that skips rendering it.
/// Mirror of Android's `ScannableCardTrustCaption`.
public struct ScannableCardTrustCaption: View {
    @Environment(\.passesSemantics) private var semantics

    public init() {}

    public var body: some View {
        // Inset rounded chip, text-only (wpass-v3u): the chip is inset from the
        // surface edges and rounded so the caption reads as an intentional
        // element rather than an edge-to-edge band; the leading pencil glyph is
        // gone. fixedSize keeps the caption from truncating at any tile size
        // (Android: softWrap false, overflow Visible). RESTYLE only — same
        // render sites, byte-for-byte wording, still no way to suppress it.
        let style = semantics?.unverifiedArtifact ?? .placeholder
        HStack {
            Text(Self.captionText)
                .font(.caption.weight(.semibold))
                .foregroundColor(style.captionForeground.swiftUIColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Self.chipRadius)
                .fill(style.captionBackground.swiftUIColor)
        )
        .padding(.horizontal, Self.chipInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inset rounded-chip geometry (wpass-v3u). Kernel-owned, not themable.
    static let chipInset: CGFloat = 12
    static let chipRadius: CGFloat = 10

    /// The exact caption copy. Wording is the load-bearing part of
    /// SCANNABLE_CARD_THREAT_MODEL.md C2; a contributor changing this string is
    /// making a security-policy edit.
    public nonisolated static let captionText = "Created by you"
}
