import PassesUICore
import SwiftUI

/// The non-suppressible "this is a user-supplied document" caption that
/// anchors the trust contract of the PDF surface (ADR 0005 D5 / D8): a PDF
/// rendered by Walt is never signature-verified, has no attestable origin,
/// and is presented under a fixed caption that the user cannot dismiss and
/// the host cannot hide.
///
/// The view has no `enabled` parameter, no theme token that hides it, and
/// no overload that skips rendering it. Mirror of Android's
/// `DocumentTrustCaption`. Adding a parameter to this view fails
/// `DocumentSurfaceLockTests`.
///
/// Hosts can restyle the caption (a flat, borderless treatment uses a
/// transparent `captionBackground`); they cannot suppress it. The icon
/// glyph is `SF Symbols`' `info.circle`, the iOS analogue of the Material
/// "info outline" path Android uses; no third-party icon dependency.
public struct DocumentTrustCaption: View {
    public init() {}

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        let style = semantics ?? .placeholder
        HStack(alignment: .center, spacing: 8) {
            InfoOutlineIcon(tint: style.captionIconTint.swiftUIColor)
            Text(Self.trustCaptionText)
                .font(.footnote)
                .foregroundColor(style.captionForeground.swiftUIColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.captionBackground.swiftUIColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.trustCaptionText)
    }

    /// The exact caption copy. Wording is the load-bearing part of ADR
    /// 0005 D5; a contributor changing this string is making a
    /// security-policy edit and the test suite requires them to update
    /// the assertion. Mirror of Android's `TRUST_CAPTION_TEXT` constant.
    ///
    /// Dual-anchor placement: the caption is composed both inside
    /// `DocumentsLane` and inside `DocumentView` so neither the
    /// wallet-list path nor a deep-linked path can bypass it. The
    /// duplication is deliberate.
    public static let trustCaptionText: String =
        "User-provided document. Walt has not verified the source."
}

extension ArgbColor {
    /// Convert a packed-ARGB color to a SwiftUI `Color`. Mirror of
    /// `passes-ui-core::toComposeColor`. Lives here as well as in
    /// `PassesUI` because `PassesPDFUI` does not depend on `PassesUI`;
    /// neither module imports the other.
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: Double(alpha) / 255.0
        )
    }
}
