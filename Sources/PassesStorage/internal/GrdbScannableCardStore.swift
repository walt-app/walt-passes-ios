import Foundation
import GRDB
import PassesCore

/// Scannable-card-table I/O. Mirrors Android's `internal/SqlCipherScannableCardStore.kt`.
/// The kernel's `ScannableCardInputValidator` is the single choke point: storage validates
/// on insert (the row never reaches disk on rejection) and reconstructs cards on read via
/// the same validator, so a row that no longer validates (e.g. after a future constraint
/// tightening) is dropped from the list rather than surfacing an unvalidated `ScannableCard`.
enum GrdbScannableCardStore {
    /// All cards, newest-first. Rows that fail re-validation are dropped (Android's
    /// `toCardOrNull`), so the consumer never sees an artifact the validator would reject.
    static func listAll(_ db: Database) throws -> [ScannableCard] {
        try Row
            .fetchAll(
                db,
                sql: "SELECT id, payload, format, label, created_at_epoch_ms "
                    + "FROM \(Schema.Tables.scannableCards) ORDER BY created_at_epoch_ms DESC, id DESC"
            )
            .compactMap(card(from:))
    }

    static func load(id: ScannableCardRecordId, _ db: Database) throws -> ScannableCard? {
        try Row.fetchOne(
            db,
            sql: "SELECT id, payload, format, label, created_at_epoch_ms "
                + "FROM \(Schema.Tables.scannableCards) WHERE id = ?",
            arguments: [id.value]
        ).flatMap(card(from:))
    }

    /// Inserts a card from already-validated, trimmed values and returns the new row id.
    static func insert(
        payload: String,
        format: ScannableFormat,
        label: String,
        nowEpochMs: Int64,
        _ db: Database
    ) throws -> ScannableCardRecordId {
        try db.execute(
            sql: "INSERT INTO \(Schema.Tables.scannableCards) "
                + "(payload, format, label, created_at_epoch_ms) VALUES (?, ?, ?, ?)",
            arguments: [payload, format.dbValue, label, nowEpochMs]
        )
        return ScannableCardRecordId(db.lastInsertedRowID)
    }

    static func delete(id: ScannableCardRecordId, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM \(Schema.Tables.scannableCards) WHERE id = ?",
            arguments: [id.value]
        )
        return db.changesCount > 0
    }

    /// Reconstructs a `ScannableCard` from a row through the validator (the only construction
    /// path). The row id becomes the consumer-visible `ScannableCardId`; a row that no longer
    /// validates returns `nil` and is dropped.
    private static func card(from row: Row) -> ScannableCard? {
        guard let format = ScannableFormat(dbValue: row["format"]) else { return nil }
        let rowId: Int64 = row["id"]
        let result = ScannableCardInputValidator.validate(
            input: ScannableCardCreateInput(payload: row["payload"], format: format, label: row["label"]),
            id: ScannableCardId(String(rowId)),
            createdAt: PassInstant(epochMillis: row["created_at_epoch_ms"])
        )
        if case .success(let card) = result { return card }
        return nil
    }
}

extension ScannableFormat {
    /// Stored in the `scannable_cards.format` column.
    var dbValue: String {
        switch self {
        case .code128: return "code128"
        case .ean13: return "ean13"
        case .upcA: return "upcA"
        case .code39: return "code39"
        case .qr: return "qr"
        }
    }

    init?(dbValue: String) {
        guard let match = ScannableFormat.allCases.first(where: { $0.dbValue == dbValue }) else { return nil }
        self = match
    }
}

extension ScannableCardCreateResult {
    /// Maps the kernel validator's rejection arms onto the storage error reason so the
    /// consumer keeps the typed reason without re-running validation.
    var storageRejectionReason: ScannableCardRejectionReason? {
        switch self {
        case .success: return nil
        case .invalidLabel(let reason): return .invalidLabel(reason: reason)
        case .invalidPayload(let reason): return .invalidPayload(reason: reason)
        case .unsupportedFormat(let format): return .unsupportedFormat(format: format)
        case .encoderFailure(let reason): return .encoderFailure(reason: reason)
        }
    }
}
