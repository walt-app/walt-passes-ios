import Foundation
import PassesCore

/// The single repository contract that walt-app's `core/data-passes` module binds against.
/// Backed by a SQLCipher database with a Keychain-wrapped key (see ADR 0002) on iOS — the
/// Android equivalent uses Keystore. This file mirrors `passes-storage`'s
/// `PassRepository.kt` 1:1 in surface; the SQL-backed implementation is deferred (see the
/// repo-level `Deferred files` list).
///
/// All trust-claim-bearing storage logic lives behind this protocol: encryption-at-rest,
/// backup exclusion, irreversible deletion, decoded summary maintenance.
///
/// Mapping from Android:
/// - `interface PassRepository { suspend fun ... }` → `protocol PassRepository: Sendable`
///   with `async` methods.
/// - `val passes: StateFlow<List<PassSummary>>` → `var passes: [PassSummary] { get async }`
///   for the current snapshot, plus `passesStream` for the cold-collect equivalent.
/// - `Flow<List<T>>` returns → `AsyncStream<[T]>`.
/// - `kotlin.Result`-style `StorageResult<T>` is preserved as the typed-error result.
public protocol PassRepository: Sendable {
    /// Current snapshot of pass summaries, sorted by `created_at_epoch_ms` descending.
    /// Backed by the `passes` row's query columns; image and locale data are NOT loaded
    /// here.
    var passes: [PassSummary] { get async }

    /// Hot stream of pass summaries. Emits the current snapshot on subscribe and re-emits
    /// on every `upsert` / `delete`. Mirrors Android's `StateFlow<List<PassSummary>>`
    /// collect path; the value side is exposed separately via `passes`.
    var passesStream: AsyncStream<[PassSummary]> { get }

    /// Insert a parsed pass, or replace an existing row whose
    /// `(type, serialNumber, organizationName)` identity matches. Returns the assigned
    /// `PassRecordId` on success.
    ///
    /// On replacement the existing image and locale rows are atomically replaced inside
    /// the same transaction. The decoded summary is recomputed from `pass`; callers do not
    /// pass a separate summary.
    func upsert(
        pass: Pass,
        signatureStatus: SignatureStatus
    ) async -> StorageResult<PassRecordId>

    /// Load a stored pass with all images and locales materialized. Use `summaryOf` for
    /// the list view; `load` is the detail-view path.
    func load(id: PassRecordId) async -> StorageResult<StoredPass>

    /// Single-pass summary lookup without materializing image/locale rows.
    func summaryOf(id: PassRecordId) async -> StorageResult<PassSummary>

    /// Irreversible delete (ADR 0002 D6). Deletes the `passes` row and its cascaded image
    /// and locale rows in one transaction, updates the `passesStream`, then emits the
    /// `onPassDeleted` telemetry event. No undo, no soft-delete, no VACUUM.
    ///
    /// Confirmation UI is the caller's responsibility; the repository trusts the call.
    func delete(id: PassRecordId) async -> StorageResult<Void>

    /// Set or clear the user-supplied display-label override on the pass with `id`. The
    /// override is stored beside the signed `pass_json` and never alters the signed
    /// identity. Normalization (mirrors passes-android):
    /// - the label is trimmed of leading/trailing whitespace before storage;
    /// - a `nil` or blank-after-trim label clears the override (writes SQL NULL);
    /// - a trimmed label longer than `PassUserLabelBounds.maxUserLabelChars` is rejected
    ///   with `StorageError.passRejected(.labelTooLong)` — the bound is checked before the
    ///   row lookup, so this takes precedence over `integrityViolation` for an unknown id.
    ///
    /// Does not bump `updated_at` (the signed pass content is unchanged). Returns
    /// `integrityViolation` when no row matches `id` and the label was within bounds.
    func updatePassUserLabel(id: PassRecordId, label: String?) async -> StorageResult<Void>

    /// Insert a stored PDF document. Bytes and thumbnail bytes are written into the
    /// `documents` and `document_thumbnails` tables in the same transaction; the assigned
    /// row id is returned. The repository never decodes `pdfBytes` or `thumbnailBytes`;
    /// they round-trip as opaque blobs. The persisted `byte_count` is `pdfBytes.count` —
    /// derived rather than caller-asserted, so a stale or zero size header from a future
    /// caller cannot bypass the cap.
    ///
    /// Defense in depth (ADR 0005 D7): rejects PDFs whose size exceeds
    /// `DocumentBounds.maxBytes` with `DocumentStorageRejectedKind.oversizedAtStorage`,
    /// page counts exceeding `DocumentBounds.maxPages` with
    /// `DocumentStorageRejectedKind.tooManyPagesAtStorage`, and labels longer than
    /// `DocumentBounds.maxLabelChars` with
    /// `DocumentStorageRejectedKind.labelTooLongAtStorage`. The renderer service in
    /// `PassesPDFCore` already enforces the size and page caps; storage carries them
    /// again so a future caller bug cannot land an oversized row. The label cap exists
    /// only at this layer.
    ///
    /// Returns `StorageError.documentRejected` when any cap is violated; the typed arm
    /// lets callers distinguish a defensive-rejection from a transient infra failure
    /// without listening to telemetry.
    func insertDocument(
        label: String,
        pdfBytes: Data,
        pageCount: Int,
        thumbnailBytes: Data
    ) async -> StorageResult<DocumentRecordId>

    /// Cold stream of document list-view rows, sorted by `imported_at_epoch_ms`
    /// descending. Emits the current snapshot on subscribe and re-emits when documents
    /// are inserted or deleted. The PDF and thumbnail blobs are NOT loaded by this
    /// stream; consumers fetch them with `loadDocumentBytes` / `loadDocumentThumbnail`
    /// on demand.
    func observeDocuments() -> AsyncStream<[DocumentRow]>

    /// Loads the raw PDF bytes for the document with `id`. The bytes are returned to the
    /// caller untouched; the storage layer never parses, sniffs, decodes, or otherwise
    /// inspects them (ADR 0005 D4).
    func loadDocumentBytes(id: DocumentRecordId) async -> StorageResult<Data>

    /// Loads the rendered thumbnail bytes for the document with `id`. Thumbnails are
    /// generated upstream by the isolated renderer service (ADR 0005 D3) and stored as
    /// opaque blobs.
    func loadDocumentThumbnail(id: DocumentRecordId) async -> StorageResult<Data>

    /// Irreversible delete of a document row and its cascaded thumbnail row in one
    /// transaction (ADR 0002 D6). Mirrors `delete` for passes: no undo, no soft-delete,
    /// no VACUUM. After the transaction commits, the document stream is updated and
    /// `onDocumentDeleted` is emitted.
    func deleteDocument(id: DocumentRecordId) async -> StorageResult<Void>

    /// Mints a `ScannableCard` from raw `input` and persists it. Storage owns the id and
    /// `createdAt` timestamp; the consumer-visible `ScannableCardId` is the stringified
    /// row id. The kernel's `ScannableCardInputValidator` is the single insert-time choke
    /// point: a validation rejection bubbles up as `StorageError.scannableCardRejected`
    /// with the typed reason preserved, never as a generic infra failure, and the row
    /// never reaches disk.
    func createScannableCard(
        input: ScannableCardCreateInput
    ) async -> StorageResult<ScannableCardRecordId>

    /// Loads a stored `ScannableCard` by row id. Returns `StorageError.integrityViolation`
    /// if no row matches.
    func loadScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<ScannableCard>

    /// Irreversible delete (ADR 0002 D6). Mirrors `delete` for passes: removes the row in
    /// one transaction, updates the `observeScannableCards` stream, then emits
    /// `onScannableCardDeleted`. No undo, no soft-delete, no VACUUM.
    func deleteScannableCard(
        id: ScannableCardRecordId
    ) async -> StorageResult<Void>

    /// Cold stream of `ScannableCard` rows sorted by `created_at_epoch_ms` descending.
    /// Emits the current snapshot on subscribe and re-emits on insert / delete. Unlike
    /// the pass and document lanes, the full card materializes here — there are no large
    /// blob columns to defer, and the consumer's tile renderer needs the payload to
    /// re-encode the barcode at render time.
    func observeScannableCards() -> AsyncStream<[ScannableCard]>

    /// Releases the underlying database connection. Idempotent: calling `close` more than
    /// once is a no-op, and method calls after `close` return `StorageError.databaseLocked`
    /// rather than throwing. Intended for consumer paths where the repository's lifetime
    /// is shorter than the process (logout, multi-user switching, instrumentation
    /// tear-down).
    ///
    /// The default singleton wiring in walt-app does not call `close`; the process exit
    /// reclaims the handle. This method exists so the contract permits explicit teardown
    /// rather than relying on process lifetime alone.
    func close()
}

/// The list-view projection of a stored pass. Mirrors the indexed columns of the `passes`
/// table so the wallet list does not pay for image or locale I/O.
public struct PassSummary: Sendable, Equatable {
    public let id: PassRecordId
    public let type: PassType
    public let serialNumber: String
    public let organizationName: String
    public let description: String
    public let expirationDate: PassInstant?
    public let voided: Bool
    public let signatureStatus: SignatureStatus
    public let createdAt: PassInstant
    public let updatedAt: PassInstant
    /// User-supplied display-label override stored beside the signed `pass_json`; `nil`
    /// when unset. Does not alter the signed pass identity.
    public let userLabel: String?

    public init(
        id: PassRecordId,
        type: PassType,
        serialNumber: String,
        organizationName: String,
        description: String,
        expirationDate: PassInstant?,
        voided: Bool,
        signatureStatus: SignatureStatus,
        createdAt: PassInstant,
        updatedAt: PassInstant,
        userLabel: String? = nil
    ) {
        self.id = id
        self.type = type
        self.serialNumber = serialNumber
        self.organizationName = organizationName
        self.description = description
        self.expirationDate = expirationDate
        self.voided = voided
        self.signatureStatus = signatureStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userLabel = userLabel
    }
}

/// The detail-view projection. The fully materialized `Pass` from `PassesCore`, plus the
/// trust band recorded at import time and the storage timestamps. Re-rendering uses `pass`
/// directly; `signatureStatus` drives the trust badge without re-running PKCS#7
/// verification.
public struct StoredPass: Sendable, Equatable {
    public let id: PassRecordId
    public let pass: Pass
    public let signatureStatus: SignatureStatus
    public let createdAt: PassInstant
    public let updatedAt: PassInstant
    /// User-supplied display-label override (see ``PassSummary/userLabel``); `nil` when unset.
    public let userLabel: String?

    public init(
        id: PassRecordId,
        pass: Pass,
        signatureStatus: SignatureStatus,
        createdAt: PassInstant,
        updatedAt: PassInstant,
        userLabel: String? = nil
    ) {
        self.id = id
        self.pass = pass
        self.signatureStatus = signatureStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userLabel = userLabel
    }
}
