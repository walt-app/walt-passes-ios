import Foundation

/// PDF import outcome. Mirror of `is.walt.passes.pdf.PdfImportResult`.
/// Scaffold for the walt-passes-ios standup; full surface lands with the
/// PassesPDFCore port bead.
public enum PDFImportResult: Sendable, Equatable {
    case success(documentId: String, pageCount: Int)
    case rejected(reason: PDFImportRejectionReason)
    case error(message: String)
}

/// Reasons a PDF import is rejected. Mirror of Android `PdfImportRejectionReason`.
public enum PDFImportRejectionReason: Sendable, Equatable {
    case invalidHeader
    case pageCountExceedsLimit
    case encrypted
    case unsupportedFeature
}
