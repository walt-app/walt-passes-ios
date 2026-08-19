import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// The widened documents lane (ios-dts.1, mirror of Android wpass-i9x / wpass-8lu):
/// `insertDocument` takes the sealed `DocumentInsert` and the row carries the
/// `format` discriminator, image dimensions, and the composite barcode pair.
/// Kind-specific rules under test: an image is one page and skips the page cap,
/// the byte cap binds every arm, a row is a composite iff BOTH barcode columns
/// decode, and unrecognised discriminators fall back (format -> pdf, barcode ->
/// no barcode) rather than throwing on a list query.
@Suite("Document kinds")
struct DocumentKindsTests {

    private func makeRepository(
        now: @escaping @Sendable () -> Int64 = { 1_000 }
    ) throws -> (GrdbPassRepository, DatabaseQueue) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_kinds_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        return (try GrdbPassRepository(dbQueue: queue, clock: now), queue)
    }

    private let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D])  // %PDF-
    private let png = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
    private let thumb = Data([0x01, 0x02])

    private func rasters(_ pages: Int) -> [DocumentPageRasterBlob] {
        (0..<pages).map { DocumentPageRasterBlob(bytes: Data([UInt8($0 + 1)]), widthPx: 10, heightPx: 10) }
    }

    private func firstRow(_ repo: GrdbPassRepository) async -> DocumentRow? {
        for await rows in repo.observeDocuments() {
            return rows.first
        }
        return nil
    }

    // MARK: - Per-arm round-trips

    @Test func pdfRowListsWithPdfFormatAndNullDimensionsAndNoBarcode() async throws {
        let (repo, _) = try makeRepository()
        let result = await repo.insertDocument(
            .pdf(label: "Boarding", bytes: pdf, thumbnailBytes: thumb, pageCount: 2, pageRasters: rasters(2)))
        guard case .success = result else {
            Issue.record("pdf insert failed: \(result)")
            return
        }

        let row = await firstRow(repo)
        #expect(row?.format == .pdf)
        #expect(row?.pageCount == 2)
        #expect(row?.widthPx == nil)
        #expect(row?.heightPx == nil)
        #expect(row?.barcodePayload == nil)
        #expect(row?.barcodeFormat == nil)
    }

    @Test func imageInsertPersistsFormatAndDimensionsAsASinglePage() async throws {
        let (repo, _) = try makeRepository()
        let result = await repo.insertDocument(
            .image(label: "Receipt", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 640, heightPx: 480))
        guard case .success(let id) = result else {
            Issue.record("image insert failed: \(result)")
            return
        }

        let row = await firstRow(repo)
        #expect(row?.format == .png)
        #expect(row?.pageCount == 1)
        #expect(row?.widthPx == 640)
        #expect(row?.heightPx == 480)
        #expect(row?.barcodePayload == nil)
        #expect(row?.barcodeFormat == nil)

        // The original image bytes round-trip opaque through the same column.
        guard case .success(let bytes) = await repo.loadDocumentBytes(id: id) else {
            Issue.record("load bytes failed")
            return
        }
        #expect(bytes == png)
    }

    @Test func barcodedImageInsertPersistsImageFieldsAndTheBarcodePair() async throws {
        let (repo, _) = try makeRepository()
        let result = await repo.insertDocument(
            .barcodedImage(
                label: "Loyalty", bytes: png, thumbnailBytes: thumb, format: .jpeg,
                widthPx: 800, heightPx: 600, barcodePayload: "MEMBER-42", barcodeFormat: .qr))
        guard case .success = result else {
            Issue.record("composite insert failed: \(result)")
            return
        }

        let row = await firstRow(repo)
        #expect(row?.format == .jpeg)
        #expect(row?.pageCount == 1)
        #expect(row?.widthPx == 800)
        #expect(row?.heightPx == 600)
        #expect(row?.barcodePayload == "MEMBER-42")
        #expect(row?.barcodeFormat == .qr)
    }

    // MARK: - Caps per arm

    @Test func imageInsertByteCapBindsInBothDirections() async throws {
        let (repo, _) = try makeRepository()
        // An image cannot violate the page cap by construction; the byte cap binds.
        let oversized = Data(count: Int(DocumentBounds.maxBytes) + 1)
        let rejected = await repo.insertDocument(
            .image(label: "Big", bytes: oversized, thumbnailBytes: thumb, format: .png, widthPx: 10, heightPx: 10))
        guard case .failure(let error) = rejected else {
            Issue.record("oversized image was accepted")
            return
        }
        #expect(error == .documentRejected(kind: .oversizedAtStorage))

        let accepted = await repo.insertDocument(
            .image(label: "Small", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 10, heightPx: 10))
        guard case .success = accepted else {
            Issue.record("in-cap image rejected: \(accepted)")
            return
        }
    }

    @Test func insertTrimsTheLabelAcrossArms() async throws {
        let (repo, _) = try makeRepository()
        let result = await repo.insertDocument(
            .image(label: "  Receipt  ", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 1, heightPx: 1))
        guard case .success = result else {
            Issue.record("insert failed: \(result)")
            return
        }
        let row = await firstRow(repo)
        #expect(row?.displayLabel == "Receipt")
    }

    // MARK: - Label updates preserve kind columns

    @Test func updateLabelOnCompositeRowPreservesKindAndBarcodeColumns() async throws {
        let (repo, _) = try makeRepository()
        let result = await repo.insertDocument(
            .barcodedImage(
                label: "Loyalty", bytes: png, thumbnailBytes: thumb, format: .png,
                widthPx: 320, heightPx: 240, barcodePayload: "P", barcodeFormat: .aztec))
        guard case .success(let id) = result else {
            Issue.record("insert failed: \(result)")
            return
        }

        guard case .success = await repo.updateDocumentLabel(id: id, label: "Gym card") else {
            Issue.record("rename failed")
            return
        }

        let row = await firstRow(repo)
        #expect(row?.displayLabel == "Gym card")
        #expect(row?.format == .png)
        #expect(row?.widthPx == 320)
        #expect(row?.heightPx == 240)
        #expect(row?.barcodePayload == "P")
        #expect(row?.barcodeFormat == .aztec)
    }

    // MARK: - Discriminator fallbacks (DB tampering; this module is the sole writer)

    @Test func unrecognisedFormatDecodesAsPdf() async throws {
        let (repo, queue) = try makeRepository()
        guard
            case .success = await repo.insertDocument(
                .pdf(label: "Doc", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1)))
        else {
            Issue.record("insert failed")
            return
        }
        try await queue.write { db in
            try db.execute(sql: "UPDATE documents SET format = 'heic'")
        }

        let rows = try await queue.read { try GrdbDocumentStore.listRows($0) }
        #expect(rows.first?.format == .pdf)
    }

    @Test func halfCompositeDecodesAsNoBarcode() async throws {
        let (repo, queue) = try makeRepository()
        guard
            case .success = await repo.insertDocument(
                .image(label: "Img", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 5, heightPx: 5))
        else {
            Issue.record("insert failed")
            return
        }
        // A payload whose format name no longer decodes must read back as NO
        // barcode, never a half-composite.
        try await queue.write { db in
            try db.execute(sql: "UPDATE documents SET barcode_payload = 'X', barcode_format = 'nonsense'")
        }

        let rows = try await queue.read { try GrdbDocumentStore.listRows($0) }
        #expect(rows.first?.barcodePayload == nil)
        #expect(rows.first?.barcodeFormat == nil)
    }

    @Test func reverseHalfCompositeAlsoDecodesAsNoBarcode() async throws {
        let (repo, queue) = try makeRepository()
        guard
            case .success = await repo.insertDocument(
                .image(label: "Img", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 5, heightPx: 5))
        else {
            Issue.record("insert failed")
            return
        }
        // The mirror tamper: a decodable format with NO payload must also read
        // back as no barcode (both-or-neither, in both directions).
        try await queue.write { db in
            try db.execute(sql: "UPDATE documents SET barcode_payload = NULL, barcode_format = 'qr'")
        }

        let rows = try await queue.read { try GrdbDocumentStore.listRows($0) }
        #expect(rows.first?.barcodePayload == nil)
        #expect(rows.first?.barcodeFormat == nil)
    }

    // MARK: - Image rows and the PDF-only raster lane

    /// The one genuinely new control flow of ios-dts.1: image arms write ZERO
    /// page-raster rows, an image row's raster read is a clean nil (never an
    /// error the self-heal would act on), and the per-page backfill refuses a
    /// non-PDF row so a wrong image row cannot grow PDF-lane artifacts later.
    @Test func imageRowsCarryNoPageRastersAndRefuseBackfill() async throws {
        let (repo, queue) = try makeRepository()
        let result = await repo.insertDocument(
            .image(label: "Img", bytes: png, thumbnailBytes: thumb, format: .png, widthPx: 5, heightPx: 5))
        guard case .success(let id) = result else {
            Issue.record("insert failed: \(result)")
            return
        }

        let rasterRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_page_rasters") ?? -1
        }
        #expect(rasterRows == 0)

        guard case .success(let raster) = await repo.loadDocumentPageRaster(id: id, page: 0) else {
            Issue.record("raster read errored for an image row")
            return
        }
        #expect(raster == nil)

        let backfill = await repo.insertDocumentPageRaster(
            id: id, page: 0,
            raster: DocumentPageRasterBlob(bytes: Data([0x01]), widthPx: 1, heightPx: 1))
        guard case .failure(let error) = backfill else {
            Issue.record("backfill landed on an image row")
            return
        }
        #expect(error == .documentRejected(kind: .pageRastersInvalidAtStorage))
    }

    /// The on-disk `format` vocabulary is frozen (the column stores these exact
    /// strings); a case rename would silently re-vocabulary the schema.
    @Test func documentFormatPersistsUnderItsFrozenRawValues() {
        #expect(DocumentFormat.pdf.rawValue == "pdf")
        #expect(DocumentFormat.png.rawValue == "png")
        #expect(DocumentFormat.jpeg.rawValue == "jpeg")
        #expect(DocumentFormat.webp.rawValue == "webp")
        #expect(DocumentFormat.allCases.count == 4)
    }

    /// The composite pair persists under the same frozen vocabulary as
    /// `scannable_cards.format`, for every symbology in the roster.
    @Test func everyBarcodeFormatRoundTripsThroughTheColumn() async throws {
        let (repo, _) = try makeRepository()
        for format in ScannableFormat.allCases {
            let result = await repo.insertDocument(
                .barcodedImage(
                    label: "L", bytes: png, thumbnailBytes: thumb, format: .png,
                    widthPx: 1, heightPx: 1, barcodePayload: "p", barcodeFormat: format))
            guard case .success = result else {
                Issue.record("insert failed for \(format)")
                return
            }
        }
        var seen: [ScannableFormat] = []
        for await rows in repo.observeDocuments() {
            seen = rows.compactMap(\.barcodeFormat)
            break
        }
        #expect(Set(seen) == Set(ScannableFormat.allCases))
    }
}
