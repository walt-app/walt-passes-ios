import Foundation
import PassesPDFCore

/// PDF thumbnail rendering surface. Mirror of `is.walt.passes.pdf.ui.PdfThumbnail`.
/// Scaffold; SwiftUI implementation lands with the PassesPDFUI port bead.
public protocol PDFThumbnailRendering: Sendable {
    func render(documentId: String, page: Int, sizeHint: CGSize) async throws -> Data
}
