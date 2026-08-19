import Foundation
import GRDB
import Testing

@testable import PassesStorage

/// Page-raster lane of the documents store (ios-dts.16 render-once): round-trip,
/// cascade delete (asserted with a direct row count), the per-page backfill
/// validation, and the pixel/byte bounds.
@Suite("GrdbDocumentStore page rasters")
struct GrdbPageRasterTests {

    private func makeRepository(now: @escaping @Sendable () -> Int64 = { 1_000 }) throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_rasters_\(UUID().uuidString).db")
        return try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: now)
    }

    private let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D])  // %PDF-
    private let thumb = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic

    /// One opaque raster blob per page; byte value varies per page so round-trip
    /// tests can tell pages apart.
    private func rasters(_ pages: Int) -> [DocumentPageRasterBlob] {
        (0..<pages).map { DocumentPageRasterBlob(bytes: Data([UInt8($0 + 1)]), widthPx: 10, heightPx: 10) }
    }

    @Test func pageRastersRoundTripAndUnknownPageIsNil() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                label: "R", pdfBytes: pdf, pageCount: 2, thumbnailBytes: thumb, pageRasters: rasters(2)
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard case .success(let page1) = await repo.loadDocumentPageRaster(id: id, page: 1) else {
            Issue.record("load raster failed")
            return
        }
        #expect(page1 == DocumentPageRasterBlob(bytes: Data([0x02]), widthPx: 10, heightPx: 10))
        // A page index with no row is a nil success (the self-heal trigger), not an error.
        guard case .success(let missing) = await repo.loadDocumentPageRaster(id: id, page: 9) else {
            Issue.record("missing raster should be nil success")
            return
        }
        #expect(missing == nil)
    }

    @Test func pageRasterForUnknownDocumentIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        let result = await repo.loadDocumentPageRaster(id: DocumentRecordId(404), page: 0)
        #expect(result == .failure(error: .integrityViolation(recordId: .document(DocumentRecordId(404)))))
    }

    @Test func insertRejectsIncompleteOrOversizedRasterSet() async throws {
        let repo = try makeRepository()
        // Count mismatch: 1 raster for a 2-page document.
        let short = await repo.insertDocument(
            label: "S", pdfBytes: pdf, pageCount: 2, thumbnailBytes: thumb, pageRasters: rasters(1)
        )
        #expect(short == .failure(error: .documentRejected(kind: .pageRastersInvalidAtStorage)))
        // Raster over the 4 MP pixel bound.
        let big = [DocumentPageRasterBlob(bytes: Data([0x01]), widthPx: 4096, heightPx: 1025)]
        let oversized = await repo.insertDocument(
            label: "O", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb, pageRasters: big
        )
        #expect(oversized == .failure(error: .documentRejected(kind: .pageRastersInvalidAtStorage)))
    }

    @Test func deleteCascadesPageRasters() async throws {
        // Keep a handle on the queue: the cascade must be asserted with a direct row
        // count, because loadDocumentPageRaster checks document existence FIRST and
        // would report integrityViolation whether or not orphaned raster rows remain.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_docs_cascade_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try GrdbDatabaseFactory.open(at: url)
        let repo = try GrdbPassRepository(dbQueue: queue, clock: { 1_000 })
        guard
            case .success(let id) = await repo.insertDocument(
                label: "C", pdfBytes: pdf, pageCount: 2, thumbnailBytes: thumb, pageRasters: rasters(2)
            )
        else {
            Issue.record("insert failed")
            return
        }
        let before = try await queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM document_page_rasters WHERE document_id = ?",
                arguments: [id.value]
            ) ?? -1
        }
        #expect(before == 2)
        _ = await repo.deleteDocument(id: id)
        let after = try await queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM document_page_rasters WHERE document_id = ?",
                arguments: [id.value]
            ) ?? -1
        }
        #expect(after == 0)
    }

    @Test func perPageBackfillWritesValidatesRangeAndBounds() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                label: "P", pdfBytes: pdf, pageCount: 2, thumbnailBytes: thumb, pageRasters: rasters(2)
            )
        else {
            Issue.record("insert failed")
            return
        }
        // In-range write replaces just that page.
        let replacement = DocumentPageRasterBlob(bytes: Data([0x0C]), widthPx: 7, heightPx: 7)
        guard case .success = await repo.insertDocumentPageRaster(id: id, page: 1, raster: replacement) else {
            Issue.record("per-page backfill failed")
            return
        }
        guard case .success(let page1) = await repo.loadDocumentPageRaster(id: id, page: 1) else {
            Issue.record("load failed")
            return
        }
        #expect(page1 == replacement)
        // Page index outside the stored page_count is rejected, not written.
        guard
            case .failure(let outOfRange) = await repo.insertDocumentPageRaster(
                id: id, page: 2, raster: replacement
            )
        else {
            Issue.record("expected out-of-range rejection")
            return
        }
        #expect(outOfRange == .documentRejected(kind: .pageRastersInvalidAtStorage))
        // Unknown document is an integrity violation.
        guard
            case .failure(let unknown) = await repo.insertDocumentPageRaster(
                id: DocumentRecordId(404), page: 0, raster: replacement
            )
        else {
            Issue.record("expected integrity violation")
            return
        }
        #expect(unknown == .integrityViolation(recordId: .document(DocumentRecordId(404))))
    }

    @Test func rasterByteCapRejectsOversizedEncodes() async throws {
        let repo = try makeRepository()
        let fat = [
            DocumentPageRasterBlob(
                bytes: Data(count: Int(DocumentBounds.maxRasterBytes) + 1), widthPx: 10, heightPx: 10
            )
        ]
        let atInsert = await repo.insertDocument(
            label: "F", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb, pageRasters: fat
        )
        #expect(atInsert == .failure(error: .documentRejected(kind: .pageRastersInvalidAtStorage)))
        guard
            case .success(let id) = await repo.insertDocument(
                label: "F2", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb, pageRasters: rasters(1)
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard
            case .failure(let atBackfill) = await repo.insertDocumentPageRaster(id: id, page: 0, raster: fat[0])
        else {
            Issue.record("expected byte-cap rejection on backfill")
            return
        }
        #expect(atBackfill == .documentRejected(kind: .pageRastersInvalidAtStorage))
    }

    @Test func aggregateRasterByteCapRejectsOnBothWritePaths() async throws {
        let repo = try makeRepository()
        // Six 20 MiB rasters: each under the per-raster cap, 120 MiB total over the
        // 100 MiB aggregate cap.
        let perRaster = Int(DocumentBounds.maxRasterBytes)
        let heavy = (0..<6).map { _ in
            DocumentPageRasterBlob(bytes: Data(count: perRaster), widthPx: 10, heightPx: 10)
        }
        let atInsert = await repo.insertDocument(
            label: "H", pdfBytes: pdf, pageCount: 6, thumbnailBytes: thumb, pageRasters: heavy
        )
        #expect(atInsert == .failure(error: .documentRejected(kind: .pageRastersInvalidAtStorage)))

        // Per-page path: four stored heavy pages (~80 MiB) + a fifth heavy backfill
        // trips the aggregate; replacing an existing heavy page (no net growth over
        // the remainder) stays legal.
        let light = DocumentPageRasterBlob(bytes: Data([0x01]), widthPx: 10, heightPx: 10)
        let fourHeavyTwoLight = Array(heavy.prefix(4)) + [light, light]
        guard
            case .success(let id) = await repo.insertDocument(
                label: "H2", pdfBytes: pdf, pageCount: 6, thumbnailBytes: thumb,
                pageRasters: fourHeavyTwoLight
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard
            case .failure(let overflow) = await repo.insertDocumentPageRaster(
                id: id, page: 5, raster: heavy[0]
            )
        else {
            Issue.record("expected aggregate-cap rejection on backfill")
            return
        }
        #expect(overflow == .documentRejected(kind: .pageRastersInvalidAtStorage))
        guard case .success = await repo.insertDocumentPageRaster(id: id, page: 0, raster: heavy[0])
        else {
            Issue.record("replacing an existing heavy page must not trip the aggregate cap")
            return
        }
    }

    @Test func rasterBoundsPinTheSharedBudgetLiterals() {
        // The 4 MP figure is deliberately duplicated across DefaultPDFImporter,
        // PDFKitRenderer, and here (module boundaries prevent one constant); each copy
        // pins it so a one-sided edit fails a test instead of failing every insert.
        #expect(DocumentBounds.maxRasterPixels == 4 * 1024 * 1024)
        #expect(DocumentBounds.maxTotalRasterBytes == 4 * DocumentBounds.maxBytes)
    }
}
