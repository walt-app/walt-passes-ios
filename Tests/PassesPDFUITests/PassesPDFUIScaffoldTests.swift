import Testing

@testable import PassesPDFUI

@Suite("PassesPDFUI scaffold")
struct PassesPDFUIScaffoldTests {

    @Test func moduleImports() {
        let _: PDFThumbnailRendering.Type? = nil
        #expect(true)
    }
}
