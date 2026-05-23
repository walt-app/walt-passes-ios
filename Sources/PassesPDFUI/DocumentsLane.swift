import SwiftUI
import PassesPDFCore

/// The Documents lane that sits below the passes list on the wallet root
/// screen. The lane renders nothing when `documents` is empty — there is
/// no empty-state placeholder, because absence-of-PDFs is not a state
/// worth chrome.
///
/// The lane has a "Documents" header followed immediately by the
/// non-suppressible `DocumentTrustCaption`. Composing the caption inside
/// the lane means the user sees the trust signal before any tile and
/// cannot scroll past it. There is no caller-supplied flag to omit the
/// caption.
///
/// Mirror of Android's `DocumentsLane`.
public struct DocumentsLane: View {
    public let documents: [PDFDocument]
    public let thumbnails: [PDFDocumentId: Image]
    public let onDocumentTap: (PDFDocument) -> Void

    public init(
        documents: [PDFDocument],
        thumbnails: [PDFDocumentId: Image],
        onDocumentTap: @escaping (PDFDocument) -> Void
    ) {
        self.documents = documents
        self.thumbnails = thumbnails
        self.onDocumentTap = onDocumentTap
    }

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        if documents.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let style = semantics ?? .placeholder
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.laneHeaderText)
                .font(.title3)
                .foregroundColor(style.tileForeground.swiftUIColor)
                .padding(.horizontal, 16)
            DocumentTrustCaption()
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(documents, id: \.id) { doc in
                        DocumentTile(
                            doc: doc,
                            thumbnail: thumbnails[doc.id],
                            onTap: { onDocumentTap(doc) }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.laneBackground.swiftUIColor)
    }

    /// Mirror of Android's `LANE_HEADER_TEXT` constant. Exposed `internal`
    /// so tests can assert the displayed header matches.
    static let laneHeaderText: String = "Documents"
}
