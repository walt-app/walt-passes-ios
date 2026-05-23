import SwiftUI

/// Non-suppressible expired/voided overlay over the parent. Mirror of Android's
/// `is.walt.passes.ui.ExpiredOverlay`. The view has no `enabled` parameter and
/// no caller-supplied flag that would hide the overlay - a pass whose validity
/// window has closed cannot present as valid through any path in this API.
public struct ExpiredOverlay: View {
    let state: ExpiredOverlayState

    public init(state: ExpiredOverlayState) {
        self.state = state
    }

    public var body: some View {
        if case .none = state {
            EmptyView()
        } else {
            content
        }
    }

    @Environment(\.passesSemantics) private var semantics

    @ViewBuilder
    private var content: some View {
        let style = semantics?.expiredBadge
        let scrimAlpha = (style?.scrimAlpha ?? 96).clamped(to: 0...255)
        ZStack {
            Color.black.opacity(Double(scrimAlpha) / 255.0)
            Text(stateLabel)
                .foregroundColor((style?.pillForeground ?? UnverifiedArtifactStyle.placeholder.captionForeground).swiftUIColor)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 100)
                        .fill((style?.pillBackground ?? UnverifiedArtifactStyle.placeholder.captionBackground).swiftUIColor)
                )
        }
    }

    private var stateLabel: String {
        switch state {
        case .voided: return "Voided"
        case .expired: return "Expired"
        case .none: return ""
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
