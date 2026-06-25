import PassesPDFCore
import PassesUICore
import SwiftUI

/// A single document entry in the Documents lane. Visually distinct from
/// `PassFront` by its smaller corner radius and its persistent "Document"
/// badge — the user reads "this is a saved file, not a signed pass" before
/// they tap.
///
/// `PDFDocument.displayLabel` is user-controlled (typically the source
/// filename). The label is wrapped in U+2068 / U+2069 (FSI / PDI) via
/// `PassesUICore::isolated(_:)` so a malicious filename carrying
/// directional-format characters cannot reorder surrounding chrome glyphs.
///
/// No share, no export, no overflow menu, no metadata. Mirror of Android's
/// `DocumentTile`.
public struct DocumentTile: View {
    public let doc: PDFDocument
    public let thumbnail: Image?
    public let onTap: () -> Void

    public init(
        doc: PDFDocument,
        thumbnail: Image?,
        onTap: @escaping () -> Void
    ) {
        self.doc = doc
        self.thumbnail = thumbnail
        self.onTap = onTap
    }

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        let style = semantics ?? .placeholder
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailBox(style: style)
                HStack(spacing: 8) {
                    Text(isolated(doc.displayLabel))
                        .font(.caption)
                        .foregroundColor(style.tileForeground.swiftUIColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DocumentBadge(style: style)
                }
            }
            .padding(8)
            .frame(width: Self.tileWidth)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(style.tileBackground.swiftUIColor)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnailBox(style: DocumentSemantics) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(style.laneBackground.swiftUIColor)
            if let thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(style.tileLabelForeground.swiftUIColor)
                    .frame(width: 48, height: 48)
            }
        }
        .aspectRatio(Self.thumbnailAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    /// Mirror of Android's `THUMBNAIL_ASPECT_RATIO` constant.
    public static let thumbnailAspectRatio: CGFloat = 4.0 / 3.0
    /// Mirror of Android's 160 dp tile width.
    public static let tileWidth: CGFloat = 160
    /// Mirror of Android's `DOCUMENT_BADGE_TEXT` constant. Exposed
    /// `internal` so tests can assert the displayed badge label matches.
    static let documentBadgeText: String = "Document"
}

private struct DocumentBadge: View {
    let style: DocumentSemantics

    var body: some View {
        Text(DocumentTile.documentBadgeText)
            .font(.caption2)
            .foregroundColor(style.documentBadgeForeground.swiftUIColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(style.documentBadgeBackground.swiftUIColor)
            )
    }
}
