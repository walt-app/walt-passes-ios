import Foundation
import PassesCore
import Testing

@testable import PassesStorage

/// Locks the `PassRepository` protocol surface. A private in-file fake conforms to the
/// full protocol; if a method signature changes or is removed without the test being
/// updated, the file fails to compile. The fake intentionally returns trivial fixtures —
/// behavioral coverage lives with the eventual SQL-backed implementation.
@Suite("PassRepositoryProtocol")
struct PassRepositoryProtocolTests {

    @Test func fakeConformsToProtocol() {
        // Compile-time check: assigning `FakePassRepository` to `any PassRepository`
        // proves the protocol surface is satisfied.
        let repo: any PassRepository = FakePassRepository()
        repo.close()
    }

    @Test func passesSnapshotReturnsEmptyByDefault() async {
        let repo: any PassRepository = FakePassRepository()
        let snapshot = await repo.passes
        #expect(snapshot.isEmpty)
    }

    @Test func upsertReturnsSuccessResultArm() async {
        let repo: any PassRepository = FakePassRepository()
        let result = await repo.upsert(pass: SamplePass.minimal, signatureStatus: .unsigned)
        switch result {
        case .success(let id):
            #expect(id.value == 1)
        case .failure:
            Issue.record("expected success, got failure")
        }
    }

    @Test func upsertFailureSurfacesStorageError() async {
        let repo = FakePassRepository(upsertResult: .failure(error: .keyUnavailable))
        let result = await (repo as any PassRepository).upsert(
            pass: SamplePass.minimal,
            signatureStatus: .unsigned
        )
        switch result {
        case .success:
            Issue.record("expected failure, got success")
        case .failure(let error):
            #expect(error == .keyUnavailable)
        }
    }

    @Test func loadReturnsStoredPassWrapping() async {
        let repo: any PassRepository = FakePassRepository()
        let result = await repo.load(id: PassRecordId(1))
        switch result {
        case .success(let stored):
            #expect(stored.id.value == 1)
            #expect(stored.signatureStatus == .unsigned)
        case .failure:
            Issue.record("expected success, got failure")
        }
    }

    @Test func summaryOfReturnsSummary() async {
        let repo: any PassRepository = FakePassRepository()
        let result = await repo.summaryOf(id: PassRecordId(1))
        switch result {
        case .success(let summary):
            #expect(summary.id.value == 1)
        case .failure:
            Issue.record("expected success, got failure")
        }
    }

    @Test func deleteReturnsVoidResult() async {
        let repo: any PassRepository = FakePassRepository()
        let result = await repo.delete(id: PassRecordId(1))
        switch result {
        case .success:
            break
        case .failure:
            Issue.record("expected success, got failure")
        }
    }

    @Test func insertDocumentRejectsOversize() async {
        let repo = FakePassRepository(
            insertDocumentResult: .failure(error: .documentRejected(kind: .oversizedAtStorage))
        )
        let result = await (repo as any PassRepository).insertDocument(
            label: "x",
            pdfBytes: Data(),
            pageCount: 1,
            thumbnailBytes: Data()
        )
        switch result {
        case .success:
            Issue.record("expected failure, got success")
        case .failure(let error):
            #expect(error == .documentRejected(kind: .oversizedAtStorage))
        }
    }

    @Test func documentBlobAccessors() async {
        let repo: any PassRepository = FakePassRepository()
        let bytes = await repo.loadDocumentBytes(id: DocumentRecordId(1))
        let thumb = await repo.loadDocumentThumbnail(id: DocumentRecordId(1))
        switch bytes {
        case .success(let data): #expect(data == Data([0x25, 0x50, 0x44, 0x46]))
        case .failure: Issue.record("expected bytes success")
        }
        switch thumb {
        case .success(let data): #expect(data == Data([0x00]))
        case .failure: Issue.record("expected thumb success")
        }
    }

    @Test func createScannableCardRouting() async {
        let repo: any PassRepository = FakePassRepository()
        let input = ScannableCardCreateInput(
            payload: "1234",
            format: .qr,
            label: "label"
        )
        let result = await repo.createScannableCard(input: input)
        switch result {
        case .success(let id): #expect(id.value == 1)
        case .failure: Issue.record("expected success")
        }
    }

    @Test func createScannableCardRejectionPreservesReason() async {
        let repo = FakePassRepository(
            createScannableCardResult: .failure(
                error: .scannableCardRejected(reason: .invalidLabel(reason: .empty))
            )
        )
        let result = await (repo as any PassRepository).createScannableCard(
            input: ScannableCardCreateInput(payload: "x", format: .qr, label: "")
        )
        switch result {
        case .success: Issue.record("expected failure")
        case .failure(let error):
            #expect(error == .scannableCardRejected(reason: .invalidLabel(reason: .empty)))
        }
    }

    @Test func observeStreamsEmitInitialSnapshot() async {
        let repo: any PassRepository = FakePassRepository()
        let docStream = repo.observeDocuments()
        let cardStream = repo.observeScannableCards()
        var docIterator = docStream.makeAsyncIterator()
        var cardIterator = cardStream.makeAsyncIterator()
        let firstDocs = await docIterator.next()
        let firstCards = await cardIterator.next()
        #expect(firstDocs?.isEmpty == true)
        #expect(firstCards?.isEmpty == true)
    }

    @Test func passesStreamEmitsInitialSnapshot() async {
        let repo: any PassRepository = FakePassRepository()
        var iterator = repo.passesStream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isEmpty == true)
    }

    @Test func closeIsCallable() {
        let repo: any PassRepository = FakePassRepository()
        repo.close()
        repo.close()
    }
}

// MARK: - Fixtures

/// Minimal `Pass` fixture for protocol-surface tests. The fake never inspects the value.
private enum SamplePass {
    static let minimal: Pass = Pass(
        type: .generic,
        serialNumber: "sn",
        description: "desc",
        organizationName: "org",
        colors: PassColors(),
        frontFields: PassFields(),
        backFields: []
    )
}

/// In-file fake. Stores per-call return overrides; defaults to "trivial success" so each
/// test can override only the arm it exercises. The fake is `final class` + `nonisolated`
/// because `PassRepository` is `Sendable` and we need a single instance across the test.
private final class FakePassRepository: PassRepository, @unchecked Sendable {
    private let upsertResult: StorageResult<PassRecordId>
    private let insertDocumentResult: StorageResult<DocumentRecordId>
    private let createScannableCardResult: StorageResult<ScannableCardRecordId>

    init(
        upsertResult: StorageResult<PassRecordId> = .success(value: PassRecordId(1)),
        insertDocumentResult: StorageResult<DocumentRecordId> = .success(
            value: DocumentRecordId(1)
        ),
        createScannableCardResult: StorageResult<ScannableCardRecordId> = .success(
            value: ScannableCardRecordId(1)
        )
    ) {
        self.upsertResult = upsertResult
        self.insertDocumentResult = insertDocumentResult
        self.createScannableCardResult = createScannableCardResult
    }

    var passes: [PassSummary] {
        get async { [] }
    }

    var passesStream: AsyncStream<[PassSummary]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }

    func upsert(
        pass: Pass,
        signatureStatus: SignatureStatus
    ) async -> StorageResult<PassRecordId> {
        upsertResult
    }

    func load(id: PassRecordId) async -> StorageResult<StoredPass> {
        .success(
            value: StoredPass(
                id: id,
                pass: SamplePass.minimal,
                signatureStatus: .unsigned,
                createdAt: PassInstant(epochMillis: 0),
                updatedAt: PassInstant(epochMillis: 0)
            )
        )
    }

    func summaryOf(id: PassRecordId) async -> StorageResult<PassSummary> {
        .success(
            value: PassSummary(
                id: id,
                type: .generic,
                serialNumber: "sn",
                organizationName: "org",
                description: "desc",
                expirationDate: nil,
                voided: false,
                signatureStatus: .unsigned,
                createdAt: PassInstant(epochMillis: 0),
                updatedAt: PassInstant(epochMillis: 0)
            )
        )
    }

    func delete(id: PassRecordId) async -> StorageResult<Void> {
        .success(value: ())
    }

    func updatePassUserLabel(id: PassRecordId, label: String?) async -> StorageResult<Void> {
        .success(value: ())
    }

    func insertDocument(
        label: String,
        pdfBytes: Data,
        pageCount: Int,
        thumbnailBytes: Data
    ) async -> StorageResult<DocumentRecordId> {
        insertDocumentResult
    }

    func observeDocuments() -> AsyncStream<[DocumentRow]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }

    func loadDocumentBytes(id: DocumentRecordId) async -> StorageResult<Data> {
        .success(value: Data([0x25, 0x50, 0x44, 0x46]))
    }

    func loadDocumentThumbnail(id: DocumentRecordId) async -> StorageResult<Data> {
        .success(value: Data([0x00]))
    }

    func deleteDocument(id: DocumentRecordId) async -> StorageResult<Void> {
        .success(value: ())
    }

    func updateDocumentLabel(id: DocumentRecordId, label: String) async -> StorageResult<Void> {
        .success(value: ())
    }

    func createScannableCard(
        input: ScannableCardCreateInput
    ) async -> StorageResult<ScannableCardRecordId> {
        createScannableCardResult
    }

    func updateScannableCard(
        id: ScannableCardRecordId,
        input: ScannableCardCreateInput
    ) async -> StorageResult<Void> {
        .success(value: ())
    }

    func loadScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<ScannableCard> {
        .failure(error: .integrityViolation(recordId: .scannableCard(id)))
    }

    func deleteScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<Void> {
        .success(value: ())
    }

    func observeScannableCards() -> AsyncStream<[ScannableCard]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }

    func close() {}
}
