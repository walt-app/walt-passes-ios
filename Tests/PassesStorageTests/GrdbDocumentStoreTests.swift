import Foundation
import GRDB
import Testing

@testable import PassesStorage

/// Behavioral coverage for the documents lane of `GrdbPassRepository` (ios-b1f.3): insert
/// round-trips the opaque PDF + thumbnail blobs, the list view omits the blobs and sorts
/// newest-first, `byte_count` is derived from the bytes, the stream re-emits on insert /
/// delete, delete is irreversible, and the storage-side defense-in-depth caps reject
/// oversized / too-many-pages / over-long-label documents with the typed kind before any
/// bytes reach disk.
@Suite("GrdbDocumentStore")
struct GrdbDocumentStoreTests {

    private func makeRepository(now: @escaping @Sendable () -> Int64 = { 1_000 }) throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_docs_\(UUID().uuidString).db")
        return try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: now)
    }

    private let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D])  // %PDF-
    private let thumb = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic

    /// One opaque raster blob per page (render-once, ios-dts.16); byte value varies per
    /// page so round-trip tests can tell pages apart.
    private func rasters(_ pages: Int) -> [DocumentPageRasterBlob] {
        (0..<pages).map { DocumentPageRasterBlob(bytes: Data([UInt8($0 + 1)]), widthPx: 10, heightPx: 10) }
    }

    @Test func insertThenLoadRoundTripsBytes() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "Boarding", bytes: pdf, thumbnailBytes: thumb, pageCount: 2, pageRasters: rasters(2))
            )
        else {
            Issue.record("insert failed")
            return
        }

        guard case .success(let bytes) = await repo.loadDocumentBytes(id: id) else {
            Issue.record("load bytes failed")
            return
        }
        guard case .success(let thumbBytes) = await repo.loadDocumentThumbnail(id: id) else {
            Issue.record("load thumb failed")
            return
        }
        #expect(bytes == pdf)
        #expect(thumbBytes == thumb)
    }

    @Test func observeEmitsListSortedNewestFirst() async throws {
        let clock = TestClock(0)
        let repo = try GrdbPassRepository(
            dbQueue: try GrdbDatabaseFactory.open(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent("walt_docs_obs_\(UUID().uuidString).db")
            ),
            clock: clock.now
        )
        var iterator = repo.observeDocuments().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)

        clock.set(10)
        _ = await repo.insertDocument(
            .pdf(label: "A", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
        )
        clock.set(20)
        _ = await repo.insertDocument(
            .pdf(label: "B", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
        )

        // After two inserts the latest emission lists B before A and carries no blob columns.
        var latest: [DocumentRow] = []
        for _ in 0..<2 { if let next = await iterator.next() { latest = next } }
        #expect(latest.map(\.displayLabel) == ["B", "A"])
        #expect(latest.first?.byteCount == Int64(pdf.count))
    }

    @Test func deleteRemovesDocumentAndAbsentIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "X", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard case .success = await repo.deleteDocument(id: id) else {
            Issue.record("delete failed")
            return
        }
        let bytes = await repo.loadDocumentBytes(id: id)
        #expect(bytes == .failure(error: .integrityViolation(recordId: .document(id))))

        guard case .failure(let error) = await repo.deleteDocument(id: id) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .integrityViolation(recordId: .document(id)))
    }

    @Test func oversizedDocumentRejectedBeforeDisk() async throws {
        let repo = try makeRepository()
        let huge = Data(count: Int(DocumentBounds.maxBytes) + 1)
        let result = await repo.insertDocument(
            .pdf(label: "big", bytes: huge, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
        )
        #expect(result == .failure(error: .documentRejected(kind: .oversizedAtStorage)))
    }

    @Test func tooManyPagesRejected() async throws {
        let repo = try makeRepository()
        let result = await repo.insertDocument(
            .pdf(
                label: "pages", bytes: pdf, thumbnailBytes: thumb,
                pageCount: DocumentBounds.maxPages + 1,
                pageRasters: rasters(DocumentBounds.maxPages + 1))
        )
        #expect(result == .failure(error: .documentRejected(kind: .tooManyPagesAtStorage)))
    }

    @Test func overLongLabelRejected() async throws {
        let repo = try makeRepository()
        let label = String(repeating: "x", count: DocumentBounds.maxLabelChars + 1)
        let result = await repo.insertDocument(
            .pdf(label: label, bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
        )
        #expect(result == .failure(error: .documentRejected(kind: .labelTooLongAtStorage)))
    }

    @Test func documentsSurviveReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_docs_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 5 })
        _ = await first.insertDocument(
            .pdf(label: "persist", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
        )
        first.close()

        let second = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 5 })
        var iterator = second.observeDocuments().makeAsyncIterator()
        #expect(await iterator.next()?.map(\.displayLabel) == ["persist"])
    }

    @Test func updateDocumentLabelChangesDisplayLabel() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "A", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard case .success = await repo.updateDocumentLabel(id: id, label: "B") else {
            Issue.record("update failed")
            return
        }
        var iterator = repo.observeDocuments().makeAsyncIterator()
        let rows = await iterator.next() ?? []
        #expect(rows.first(where: { $0.id == id })?.displayLabel == "B")
    }

    /// Mirror of Android `updateLabelTrimsEdgesAndFoldsBlankToEmpty` (wpass-tjc.1).
    @Test func updateDocumentLabelTrimsEdgesAndFoldsBlankToEmpty() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "seed", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }

        // Edges trimmed, internal whitespace preserved (mirrors updatePassUserLabel).
        guard case .success = await repo.updateDocumentLabel(id: id, label: "  My Boarding Pass  ")
        else {
            Issue.record("update failed")
            return
        }
        #expect(await currentLabel(repo, id: id) == "My Boarding Pass")

        // Blank-after-trim folds to "" — the non-null column's cleared state.
        _ = await repo.updateDocumentLabel(id: id, label: "   ")
        #expect(await currentLabel(repo, id: id) == "")
    }

    /// Mirror of Android `updateLabelMeasuresCapAgainstTrimmedValue` (wpass-tjc.1).
    @Test func updateDocumentLabelMeasuresCapAgainstTrimmedValue() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "seed", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }

        let maxLabel = String(repeating: "a", count: DocumentBounds.maxLabelChars)
        let padded = "  " + maxLabel + "  "
        #expect(padded.count > DocumentBounds.maxLabelChars)
        guard case .success = await repo.updateDocumentLabel(id: id, label: padded) else {
            Issue.record("padded at-cap label should be accepted after trim")
            return
        }
        #expect(await currentLabel(repo, id: id) == maxLabel)
    }

    /// Mirror of Android `insertTrimsLabelAndFoldsBlankToEmptyMatchingUpdate` (wpass-tjc.1):
    /// both paths writing display_label agree.
    @Test func insertDocumentTrimsLabelAndFoldsBlankToEmpty() async throws {
        let repo = try makeRepository()
        guard
            case .success(let trimmedId) = await repo.insertDocument(
                .pdf(
                    label: "  boarding pass  ", bytes: pdf, thumbnailBytes: thumb,
                    pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }
        guard
            case .success(let blankId) = await repo.insertDocument(
                .pdf(label: "   ", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("blank insert failed")
            return
        }
        #expect(await currentLabel(repo, id: trimmedId) == "boarding pass")
        #expect(await currentLabel(repo, id: blankId) == "")
    }

    private func currentLabel(_ repo: GrdbPassRepository, id: DocumentRecordId) async -> String? {
        var iterator = repo.observeDocuments().makeAsyncIterator()
        let rows = await iterator.next() ?? []
        return rows.first(where: { $0.id == id })?.displayLabel
    }

    @Test func updateDocumentLabelAtCapAcceptedOverCapRejected() async throws {
        let repo = try makeRepository()
        guard
            case .success(let id) = await repo.insertDocument(
                .pdf(label: "A", bytes: pdf, thumbnailBytes: thumb, pageCount: 1, pageRasters: rasters(1))
            )
        else {
            Issue.record("insert failed")
            return
        }
        let atCap = String(repeating: "x", count: DocumentBounds.maxLabelChars)
        guard case .success = await repo.updateDocumentLabel(id: id, label: atCap) else {
            Issue.record("at-cap label should be accepted")
            return
        }
        let overCap = String(repeating: "x", count: DocumentBounds.maxLabelChars + 1)
        guard case .failure(let error) = await repo.updateDocumentLabel(id: id, label: overCap) else {
            Issue.record("expected over-cap rejection")
            return
        }
        #expect(error == .documentRejected(kind: .labelTooLongAtStorage))
    }

    @Test func updateDocumentLabelCapRejectionPrecedesUnknownId() async throws {
        let repo = try makeRepository()
        let overCap = String(repeating: "x", count: DocumentBounds.maxLabelChars + 1)
        // Cap is checked before the row lookup: too-long on an unknown id is documentRejected.
        guard case .failure(let error) = await repo.updateDocumentLabel(id: DocumentRecordId(404), label: overCap)
        else {
            Issue.record("expected cap rejection")
            return
        }
        #expect(error == .documentRejected(kind: .labelTooLongAtStorage))
    }

    @Test func updateDocumentLabelUnknownIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard case .failure(let error) = await repo.updateDocumentLabel(id: DocumentRecordId(404), label: "x") else {
            Issue.record("expected integrity violation")
            return
        }
        #expect(error == .integrityViolation(recordId: .document(DocumentRecordId(404))))
    }

    /// Mutable, thread-safe clock (Swift 6 rejects a captured `var` in a `@Sendable` closure).
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        func set(_ value: Int64) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
        var now: @Sendable () -> Int64 {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
    }
}
