import Testing

@testable import PassesPDFCore

@Suite("PDFImportResult scaffold")
struct PDFImportResultTests {

    @Test func successCaseCarriesPageCount() {
        let result = PDFImportResult.success(documentId: "doc-1", pageCount: 3)
        if case .success(_, let pages) = result {
            #expect(pages == 3)
        } else {
            Issue.record("Expected .success case")
        }
    }
}
