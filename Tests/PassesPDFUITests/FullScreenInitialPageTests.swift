import PassesPDFCore
import Testing

@testable import PassesPDFUI

/// Pins the `initialPage` clamp and the pager's seeded selection (Android's
/// `FullScreenDocumentInitialPageTest` records the first render instead).
@MainActor
@Suite("Full-screen initial page")
struct FullScreenInitialPageTests {

    @Test func opensOnTheRequestedPage() {
        #expect(FullScreenPdfView.clampedInitialPage(2, pageCount: 4) == 2)
    }

    @Test func defaultsToTheFirstPage() {
        let view = FullScreenDocumentView(doc: doc(pageCount: 4), pages: EmptyPageSource(), onClose: {})
        #expect(view.initialPage == 0)
    }

    @Test func clampsAPageBeyondTheEndToTheLastPage() {
        #expect(FullScreenPdfView.clampedInitialPage(99, pageCount: 4) == 3)
    }

    @Test func clampsANegativePageToTheFirstPage() {
        #expect(FullScreenPdfView.clampedInitialPage(-1, pageCount: 4) == 0)
    }

    @Test func aDocumentWithNoPagesClampsToZeroInsteadOfTrapping() {
        #expect(FullScreenPdfView.clampedInitialPage(3, pageCount: 0) == 0)
    }

    @Test func aSinglePageDocumentOpensOnItsOnlyPage() {
        #expect(FullScreenPdfView.clampedInitialPage(5, pageCount: 1) == 0)
    }

    /// The clamp is only useful if the pager's selection starts from it:
    /// outside a view hierarchy `@State` reads back its initial value.
    @Test func thePagerSeedsItsSelectionFromTheClampedPage() {
        let pager = FullScreenPdfView(
            doc: doc(pageCount: 4), pages: EmptyPageSource(),
            telemetry: DocumentTelemetryGuardNoOp.shared, initialPage: 99)
        #expect(pager.currentPage == 3)
    }

    private func doc(pageCount: Int) -> PDFDocument {
        PDFDocument(
            id: PDFDocumentId("doc-initial-page"), displayLabel: "doc.pdf", byteCount: 1024,
            pageCount: pageCount, importedAtEpochMs: 0)
    }
}

/// Never read: construction only.
private struct EmptyPageSource: DocumentPageSource {
    func pageRaster(page: Int) async -> StoredPageRaster? { nil }
}
