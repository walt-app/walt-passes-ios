import Foundation

/// The outcome of attempting to import a PDF. Modelled as a sum type so the consumer
/// gets compile-time exhaustiveness when branching on import results, mirroring the
/// `ParseResult` shape in `PassesCore`.
///
/// There is intentionally no `tampered` arm here: PDFs are not signature-verified (ADR 0005
/// D5), so "tampered" is not a category Walt can detect or report. Consumers wanting to
/// communicate "this is just a file" should rely on the absence of a signature-status type
/// on `PDFDocument` rather than expecting an explicit Untrusted arm.
public enum PDFImportResult: Sendable, Equatable {
    case imported(doc: PDFDocument)
    case rejected(kind: DocumentRejectedKind)
}
