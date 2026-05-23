import SwiftUI
import PassesUICore

/// SwiftUI environment key carrying the host-supplied `PassesSemantics`.
/// Reading this outside a `passesTheme(_:)` scope returns a hard-coded fail
/// fixture so a forgotten wrapper is visible in development.
public struct PassesSemanticsKey: EnvironmentKey {
    public static let defaultValue: PassesSemantics? = nil
}

public extension EnvironmentValues {
    var passesSemantics: PassesSemantics? {
        get { self[PassesSemanticsKey.self] }
        set { self[PassesSemanticsKey.self] = newValue }
    }
}

public extension View {
    /// The host's entry point into PassesUI. Wraps `content` so every PassesUI view
    /// can read `\.passesSemantics`. Mirror of Android's `PassesTheme` composable
    /// and `LocalPassesSemantics` CompositionLocal.
    func passesTheme(_ semantics: PassesSemantics) -> some View {
        environment(\.passesSemantics, semantics)
    }
}

extension ArgbColor {
    /// Convert a packed-ARGB color to a SwiftUI `Color`. Forwards a sRGB
    /// component triplet plus alpha; mirrors `passes-ui-core::toComposeColor`.
    public var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: Double(alpha) / 255.0
        )
    }
}
