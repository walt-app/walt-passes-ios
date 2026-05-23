import SwiftUI
import PassesUICore

/// SwiftUI environment key carrying the host-supplied `DocumentSemantics`.
/// Reading this outside a `documentTheme(_:)` scope returns `nil`; consuming
/// views fall back to a placeholder palette so a forgotten wrapper is visible
/// in development rather than crashing. Mirror of Android's
/// `LocalDocumentSemantics` CompositionLocal.
public struct DocumentSemanticsKey: EnvironmentKey {
    public static let defaultValue: DocumentSemantics? = nil
}

public extension EnvironmentValues {
    var documentSemantics: DocumentSemantics? {
        get { self[DocumentSemanticsKey.self] }
        set { self[DocumentSemanticsKey.self] = newValue }
    }
}

public extension View {
    /// Wraps `content` so every PassesPDFUI view can read
    /// `\.documentSemantics`. Mirror of Android's `DocumentTheme` composable.
    func documentTheme(_ semantics: DocumentSemantics) -> some View {
        environment(\.documentSemantics, semantics)
    }
}

extension DocumentSemantics {
    /// Neutral grayscale placeholder so previews and tests render without a
    /// host theme. Hosts MUST override in production.
    public static let placeholder = DocumentSemantics(
        captionBackground: ArgbColor(argb: 0xFF202020),
        captionForeground: ArgbColor(argb: 0xFFFFFFFF),
        tileBackground: ArgbColor(argb: 0xFFF5F5F5),
        tileForeground: ArgbColor(argb: 0xFF202020),
        tileLabelForeground: ArgbColor(argb: 0xFF606060),
        laneBackground: ArgbColor(argb: 0xFFEEEEEE),
        documentBadgeBackground: ArgbColor(argb: 0xFFD0D0D0),
        documentBadgeForeground: ArgbColor(argb: 0xFF202020)
    )
}
