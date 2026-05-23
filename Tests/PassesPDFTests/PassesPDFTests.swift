import Foundation
import PassesCore
import Testing

@testable import PassesPDF

/// Placeholder smoke test — exercises a no-op `PDFImporter` so the test
/// bundle stays non-empty until the production importer ships.
@Suite("PassesPDF")
struct PassesPDFTests {

    private struct ThrowingPDFImporter: PDFImporter {
        func importPDF(at url: URL) async throws -> Pass {
            throw CancellationError()
        }
    }

    @Test func placeholderImporterRejectsImports() async {
        let importer = ThrowingPDFImporter()
        await #expect(throws: CancellationError.self) {
            _ = try await importer.importPDF(at: URL(fileURLWithPath: "/dev/null"))
        }
    }
}
