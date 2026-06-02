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
    private let thumb = Data([0x89, 0x50, 0x4E, 0x47])      // PNG magic

    @Test func insertThenLoadRoundTripsBytes() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.insertDocument(
            label: "Boarding", pdfBytes: pdf, pageCount: 2, thumbnailBytes: thumb
        ) else { Issue.record("insert failed"); return }

        guard case .success(let bytes) = await repo.loadDocumentBytes(id: id) else {
            Issue.record("load bytes failed"); return
        }
        guard case .success(let thumbBytes) = await repo.loadDocumentThumbnail(id: id) else {
            Issue.record("load thumb failed"); return
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
        _ = await repo.insertDocument(label: "A", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb)
        clock.set(20)
        _ = await repo.insertDocument(label: "B", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb)

        // After two inserts the latest emission lists B before A and carries no blob columns.
        var latest: [DocumentRow] = []
        for _ in 0..<2 { if let next = await iterator.next() { latest = next } }
        #expect(latest.map(\.displayLabel) == ["B", "A"])
        #expect(latest.first?.byteCount == Int64(pdf.count))
    }

    @Test func deleteRemovesDocumentAndAbsentIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.insertDocument(
            label: "X", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb
        ) else { Issue.record("insert failed"); return }
        guard case .success = await repo.deleteDocument(id: id) else {
            Issue.record("delete failed"); return
        }
        let bytes = await repo.loadDocumentBytes(id: id)
        #expect(bytes == .failure(error: .integrityViolation(recordId: .document(id))))

        guard case .failure(let error) = await repo.deleteDocument(id: id) else {
            Issue.record("expected failure"); return
        }
        #expect(error == .integrityViolation(recordId: .document(id)))
    }

    @Test func oversizedDocumentRejectedBeforeDisk() async throws {
        let repo = try makeRepository()
        let huge = Data(count: Int(DocumentBounds.maxBytes) + 1)
        let result = await repo.insertDocument(label: "big", pdfBytes: huge, pageCount: 1, thumbnailBytes: thumb)
        #expect(result == .failure(error: .documentRejected(kind: .oversizedAtStorage)))
    }

    @Test func tooManyPagesRejected() async throws {
        let repo = try makeRepository()
        let result = await repo.insertDocument(
            label: "pages", pdfBytes: pdf, pageCount: DocumentBounds.maxPages + 1, thumbnailBytes: thumb
        )
        #expect(result == .failure(error: .documentRejected(kind: .tooManyPagesAtStorage)))
    }

    @Test func overLongLabelRejected() async throws {
        let repo = try makeRepository()
        let label = String(repeating: "x", count: DocumentBounds.maxLabelChars + 1)
        let result = await repo.insertDocument(label: label, pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb)
        #expect(result == .failure(error: .documentRejected(kind: .labelTooLongAtStorage)))
    }

    @Test func documentsSurviveReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_docs_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 5 })
        _ = await first.insertDocument(label: "persist", pdfBytes: pdf, pageCount: 1, thumbnailBytes: thumb)
        first.close()

        let second = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 5 })
        var iterator = second.observeDocuments().makeAsyncIterator()
        #expect(await iterator.next()?.map(\.displayLabel) == ["persist"])
    }

    /// Mutable, thread-safe clock (Swift 6 rejects a captured `var` in a `@Sendable` closure).
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        func set(_ value: Int64) { lock.lock(); self.value = value; lock.unlock() }
        var now: @Sendable () -> Int64 { { [self] in lock.lock(); defer { lock.unlock() }; return value } }
    }
}
