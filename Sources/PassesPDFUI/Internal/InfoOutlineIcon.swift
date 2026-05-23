import SwiftUI

/// "Info outline" glyph used by `DocumentTrustCaption`. On iOS the SF
/// Symbols system carries `info.circle`, which is the exact Material
/// "info outline" equivalent shipped by Apple; this view renders it tinted
/// by the supplied color. Avoids the multi-megabyte
/// `material-icons-extended` dependency Android sidesteps by hand-authoring
/// the path, while still staying out of any third-party icon pack.
struct InfoOutlineIcon: View {
    let tint: Color
    let size: CGFloat

    init(tint: Color, size: CGFloat = 16) {
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Image(systemName: "info.circle")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
