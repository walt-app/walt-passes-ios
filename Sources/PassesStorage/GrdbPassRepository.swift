import Foundation
import GRDB
import PassesCore

/// The concrete `PassRepository`, backed by GRDB over Apple's built-in SQLite with
/// encryption-at-rest provided by iOS Data Protection on the DB file (ios-b1f decision,
/// 2026-06-02). Mirrors Android's `SqlCipherPassRepository`; named for the actual technology
/// (GRDB) rather than Android's `SqlCipher*` name, since there is no SQLCipher here — a
/// `SqlCipher`-named class with no SQLCipher would mislead a security reviewer.
///
/// `final class` + `@unchecked Sendable` rather than an `actor`: GRDB's `DatabaseQueue`
/// already serializes all reads/writes, and the only other shared state — the snapshot
/// broadcasters and the `closed` flag — is lock-guarded. An actor would force the
/// synchronous, non-isolated stream accessors (`passesStream`, `observeDocuments`,
/// `observeScannableCards`, `close`) the protocol declares to become `await`-ed, which they
/// cannot be.
///
/// Write semantics mirror Android: each mutation runs in a single `dbQueue.write`
/// transaction; afterwards the affected snapshot is recomputed and broadcast. Deletes are
/// irreversible (no soft-delete, no VACUUM).
///
/// **Scope (ios-b1f.2):** the passes lane (`upsert`/`load`/`summaryOf`/`delete`/`passes`/
/// `passesStream`) is fully implemented. The documents lane (ios-b1f.3) and scannable-card
/// lane (ios-b1f.4) are placeholders that keep the type conforming to `PassRepository`; they
/// land in their own beads.
public final class GrdbPassRepository: PassRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let clock: @Sendable () -> Int64

    private let passesBroadcaster: Broadcaster<[PassSummary]>
    private let documentsBroadcaster: Broadcaster<[DocumentRow]>
    private let scannableBroadcaster: Broadcaster<[ScannableCard]>

    private let stateLock = NSLock()
    private var closed = false

    /// Opens a repository over an already-migrated `DatabaseQueue` (see `GrdbDatabaseFactory`)
    /// and seeds the snapshots from disk. `clock` is injected for deterministic tests; it
    /// defaults to wall-clock epoch milliseconds.
    public init(
        dbQueue: DatabaseQueue,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        self.dbQueue = dbQueue
        self.clock = clock
        let (summaries, documents, cards) = try dbQueue.read {
            (
                try GrdbPassStore.listSummaries($0),
                try GrdbDocumentStore.listRows($0),
                try GrdbScannableCardStore.listAll($0)
            )
        }
        passesBroadcaster = Broadcaster(summaries)
        documentsBroadcaster = Broadcaster(documents)
        scannableBroadcaster = Broadcaster(cards)
    }

    private func ensureOpen() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !closed
    }

    // MARK: - Passes

    public var passes: [PassSummary] {
        get async { passesBroadcaster.value }
    }

    public var passesStream: AsyncStream<[PassSummary]> {
        passesBroadcaster.stream()
    }

    public func upsert(
        pass: Pass,
        signatureStatus: SignatureStatus
    ) async -> StorageResult<PassRecordId> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        let now = clock()
        do {
            let id = try await dbQueue.write { db in
                try GrdbPassStore.upsert(pass: pass, signatureStatus: signatureStatus, nowEpochMs: now, db)
            }
            await refreshPasses()
            return .success(value: id)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func load(id: PassRecordId) async -> StorageResult<StoredPass> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            guard let stored = try await dbQueue.read({ try GrdbPassStore.load(byId: id, $0) }) else {
                return .failure(error: .integrityViolation(recordId: .pass(id)))
            }
            return .success(value: stored)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func summaryOf(id: PassRecordId) async -> StorageResult<PassSummary> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            guard let summary = try await dbQueue.read({ try GrdbPassStore.summary(byId: id, $0) }) else {
                return .failure(error: .integrityViolation(recordId: .pass(id)))
            }
            return .success(value: summary)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func delete(id: PassRecordId) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            let existed = try await dbQueue.write { db in try GrdbPassStore.delete(byId: id, db) }
            guard existed else { return .failure(error: .integrityViolation(recordId: .pass(id))) }
            await refreshPasses()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func updatePassUserLabel(id: PassRecordId, label: String?) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        // Normalize: trim, then collapse blank-after-trim to nil (a clear). The trimmed
        // value is what the cap is measured against and what reaches the store.
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Cap is checked before the row lookup, so a too-long label on an unknown id
        // surfaces as `.passRejected`, not `.integrityViolation`.
        if let normalized, normalized.count > PassUserLabelBounds.maxUserLabelChars {
            return .failure(error: .passRejected(kind: .labelTooLong))
        }
        do {
            let existed = try await dbQueue.write { db in
                try GrdbPassStore.updateUserLabel(id: id, label: normalized, db)
            }
            guard existed else { return .failure(error: .integrityViolation(recordId: .pass(id))) }
            await refreshPasses()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    private func refreshPasses() async {
        guard let summaries = try? await dbQueue.read({ try GrdbPassStore.listSummaries($0) }) else { return }
        passesBroadcaster.send(summaries)
    }

    // MARK: - Documents

    public func insertDocument(
        label: String,
        pdfBytes: Data,
        pageCount: Int,
        thumbnailBytes: Data
    ) async -> StorageResult<DocumentRecordId> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        // Same label normalization as updateDocumentLabel, so both paths writing
        // display_label agree (an all-whitespace label cannot land at import either).
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind = GrdbDocumentStore.rejection(pdfBytes: pdfBytes, pageCount: pageCount, label: label) {
            return .failure(error: .documentRejected(kind: kind))
        }
        let now = clock()
        do {
            let id = try await dbQueue.write { db in
                try GrdbDocumentStore.insert(
                    GrdbDocumentStore.Insert(
                        label: label, pdfBytes: pdfBytes, pageCount: pageCount,
                        thumbnailBytes: thumbnailBytes, nowEpochMs: now
                    ),
                    db
                )
            }
            await refreshDocuments()
            return .success(value: id)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func updateDocumentLabel(id: DocumentRecordId, label: String) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        // Normalize like updatePassUserLabel: trim, measure the cap against the trimmed
        // value (mirror of Android). Blank folds to "" — empty labels are allowed here.
        // Cap checked before the row lookup, so a too-long label on an unknown id surfaces
        // as `.documentRejected`, not `.integrityViolation`.
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count > DocumentBounds.maxLabelChars {
            return .failure(error: .documentRejected(kind: .labelTooLongAtStorage))
        }
        do {
            let matched = try await dbQueue.write { db in
                try GrdbDocumentStore.updateLabel(id: id, label: normalized, db)
            }
            guard matched else { return .failure(error: .integrityViolation(recordId: .document(id))) }
            await refreshDocuments()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func observeDocuments() -> AsyncStream<[DocumentRow]> {
        documentsBroadcaster.stream()
    }

    public func loadDocumentBytes(id: DocumentRecordId) async -> StorageResult<Data> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            guard let bytes = try await dbQueue.read({ try GrdbDocumentStore.loadBytes(id: id, $0) }) else {
                return .failure(error: .integrityViolation(recordId: .document(id)))
            }
            return .success(value: bytes)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func loadDocumentThumbnail(id: DocumentRecordId) async -> StorageResult<Data> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            guard let bytes = try await dbQueue.read({ try GrdbDocumentStore.loadThumbnail(id: id, $0) }) else {
                return .failure(error: .integrityViolation(recordId: .document(id)))
            }
            return .success(value: bytes)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func deleteDocument(id: DocumentRecordId) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            let existed = try await dbQueue.write { db in try GrdbDocumentStore.delete(id: id, db) }
            guard existed else { return .failure(error: .integrityViolation(recordId: .document(id))) }
            await refreshDocuments()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    private func refreshDocuments() async {
        guard let rows = try? await dbQueue.read({ try GrdbDocumentStore.listRows($0) }) else { return }
        documentsBroadcaster.send(rows)
    }

    // MARK: - Scannable cards

    public func createScannableCard(
        input: ScannableCardCreateInput
    ) async -> StorageResult<ScannableCardRecordId> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        let now = clock()
        let validated: ScannableCard
        switch approveScannableCard(input: input, nowEpochMs: now) {
        case .success(let approved): validated = approved
        case .failure(let error): return .failure(error: error)
        }
        do {
            // Persist the validator's trimmed, normalized values, not the raw input.
            let id = try await dbQueue.write { db in
                try GrdbScannableCardStore.insert(
                    payload: validated.payload, format: validated.format,
                    label: validated.label, nowEpochMs: now, db
                )
            }
            await refreshScannableCards()
            return .success(value: id)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func updateScannableCard(
        id: ScannableCardRecordId,
        input: ScannableCardCreateInput
    ) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        let now = clock()
        // The same approval gate as create, run before the row lookup — an invalid input
        // on an unknown id surfaces as .scannableCardRejected, and a rejected edit cannot
        // turn a rendering card into a blank one.
        let validated: ScannableCard
        switch approveScannableCard(input: input, nowEpochMs: now) {
        case .success(let approved): validated = approved
        case .failure(let error): return .failure(error: error)
        }
        do {
            let matched = try await dbQueue.write { db in
                try GrdbScannableCardStore.updateById(
                    id: id, payload: validated.payload, format: validated.format,
                    label: validated.label, db
                )
            }
            guard matched else { return .failure(error: .integrityViolation(recordId: .scannableCard(id))) }
            await refreshScannableCards()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func loadScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<ScannableCard> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            guard let card = try await dbQueue.read({ try GrdbScannableCardStore.load(id: id, $0) }) else {
                return .failure(error: .integrityViolation(recordId: .scannableCard(id)))
            }
            return .success(value: card)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func deleteScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<Void> {
        guard ensureOpen() else { return .failure(error: .databaseLocked) }
        do {
            let existed = try await dbQueue.write { db in try GrdbScannableCardStore.delete(id: id, db) }
            guard existed else { return .failure(error: .integrityViolation(recordId: .scannableCard(id))) }
            await refreshScannableCards()
            return .success(value: ())
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }

    public func observeScannableCards() -> AsyncStream<[ScannableCard]> {
        scannableBroadcaster.stream()
    }

    /// The approval gate both scannable-card write paths share: kernel validation, then
    /// a trial encode of what the validator approved, with the encoder refusal folded
    /// onto the same `storageRejectionReason` mapping as `.encoderFailure` (wpass-1kg;
    /// rationale in `BarcodeEncoder`'s doc and ADR `passes-ui-2`). The encoded symbol is
    /// discarded — one encode per save on a non-hot path. The `ScannableCardId` is a
    /// placeholder: the validator does not read it; storage mints the real id at insert
    /// and preserves it across an update.
    private func approveScannableCard(
        input: ScannableCardCreateInput, nowEpochMs: Int64
    ) -> StorageResult<ScannableCard> {
        let validation = ScannableCardInputValidator.validate(
            input: input,
            id: ScannableCardId("0"),
            createdAt: PassInstant(epochMillis: nowEpochMs)
        )
        // Only an approved card is worth an encode; every other arm passes through
        // untouched to the single mapping below.
        let approval: ScannableCardCreateResult
        if case .success(let card) = validation {
            approval = trialEncode(card)
        } else {
            approval = validation
        }
        guard case .success(let approved) = approval else {
            return .failure(
                error: .scannableCardRejected(
                    reason: approval.storageRejectionReason ?? .invalidPayload(reason: .empty)
                ))
        }
        return .success(value: approved)
    }

    /// Re-approves `card` only if its `(payload, format)` actually encodes.
    private func trialEncode(_ card: ScannableCard) -> ScannableCardCreateResult {
        switch BarcodeEncoder.encode(payload: card.payload, format: card.format) {
        case .success: return .success(card: card)
        case .failure(let reason): return .encoderFailure(reason: reason)
        }
    }

    private func refreshScannableCards() async {
        guard let cards = try? await dbQueue.read({ try GrdbScannableCardStore.listAll($0) }) else { return }
        scannableBroadcaster.send(cards)
    }

    // MARK: - Lifecycle

    public func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        passesBroadcaster.finish()
        documentsBroadcaster.finish()
        scannableBroadcaster.finish()
    }
}
