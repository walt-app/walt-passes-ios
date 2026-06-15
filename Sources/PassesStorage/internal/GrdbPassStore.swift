import Foundation
import GRDB
import PassesCore

/// Pass-table I/O: the `passes` row plus its cascaded `pass_images` and `pass_locales`
/// children. Mirrors Android's `internal/SqlCipherPassStore.kt`. Every function takes the
/// GRDB `Database` handle so the owning repository controls the transaction boundary
/// (`dbQueue.write` / `dbQueue.read`); the store itself holds no state.
enum GrdbPassStore {
    /// Columns backing `PassSummary`, in a fixed order.
    private static let summaryColumns = """
        id, type, serial_number, organization_name, description, expiration_epoch_ms, \
        voided, signature_status_kind, created_at_epoch_ms, updated_at_epoch_ms, user_label
        """

    static func listSummaries(_ db: Database) throws -> [PassSummary] {
        try Row
            .fetchAll(
                db,
                sql: "SELECT \(summaryColumns) FROM \(Schema.Tables.passes) "
                    + "ORDER BY created_at_epoch_ms DESC, id DESC"
            )
            .compactMap(summary(from:))
    }

    static func summary(byId id: PassRecordId, _ db: Database) throws -> PassSummary? {
        try Row
            .fetchOne(
                db,
                sql: "SELECT \(summaryColumns) FROM \(Schema.Tables.passes) WHERE id = ?",
                arguments: [id.value]
            )
            .flatMap(summary(from:))
    }

    static func load(byId id: PassRecordId, _ db: Database) throws -> StoredPass? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: "SELECT \(summaryColumns), pass_json FROM \(Schema.Tables.passes) WHERE id = ?",
                arguments: [id.value]
            ),
            let summary = summary(from: row)
        else { return nil }

        let base = try PassBlob.decode(row["pass_json"])
        let pass = Pass(
            type: base.type,
            serialNumber: base.serialNumber,
            description: base.description,
            organizationName: base.organizationName,
            expirationDate: base.expirationDate,
            voided: base.voided,
            colors: base.colors,
            frontFields: base.frontFields,
            backFields: base.backFields,
            barcode: base.barcode,
            images: try readImages(passId: id, db),
            locales: try readLocales(passId: id, db)
        )
        return StoredPass(
            id: summary.id,
            pass: pass,
            signatureStatus: summary.signatureStatus,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            userLabel: summary.userLabel
        )
    }

    /// Insert, or replace the row whose `(type, serial_number, organization_name)` identity
    /// matches. On replacement the `created_at` is preserved and the image/locale children
    /// are dropped and re-inserted, all within the caller's transaction.
    static func upsert(
        pass: Pass,
        signatureStatus: SignatureStatus,
        nowEpochMs: Int64,
        _ db: Database
    ) throws -> PassRecordId {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT id, created_at_epoch_ms FROM \(Schema.Tables.passes) "
                + "WHERE type = ? AND serial_number = ? AND organization_name = ?",
            arguments: [pass.type.dbValue, pass.serialNumber, pass.organizationName]
        )
        let existingId: Int64? = existing.map { $0["id"] }
        let createdAt: Int64 = existing.map { $0["created_at_epoch_ms"] } ?? nowEpochMs
        let kind = signatureStatus.toKind().dbValue
        let passJson = try PassBlob.encode(pass)

        let rowId: Int64
        if let existingId {
            try db.execute(
                sql: """
                    UPDATE \(Schema.Tables.passes) SET
                        type = ?, serial_number = ?, organization_name = ?, description = ?,
                        expiration_epoch_ms = ?, voided = ?, signature_status_kind = ?,
                        pass_json = ?, updated_at_epoch_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    pass.type.dbValue, pass.serialNumber, pass.organizationName, pass.description,
                    pass.expirationDate?.epochMillis, pass.voided ? 1 : 0, kind,
                    passJson, nowEpochMs, existingId,
                ]
            )
            try db.execute(
                sql: "DELETE FROM \(Schema.Tables.passImages) WHERE pass_id = ?",
                arguments: [existingId]
            )
            try db.execute(
                sql: "DELETE FROM \(Schema.Tables.passLocales) WHERE pass_id = ?",
                arguments: [existingId]
            )
            rowId = existingId
        } else {
            try db.execute(
                sql: """
                    INSERT INTO \(Schema.Tables.passes)
                        (type, serial_number, organization_name, description, expiration_epoch_ms,
                         voided, signature_status_kind, pass_json, created_at_epoch_ms,
                         updated_at_epoch_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    pass.type.dbValue, pass.serialNumber, pass.organizationName, pass.description,
                    pass.expirationDate?.epochMillis, pass.voided ? 1 : 0, kind, passJson,
                    createdAt, nowEpochMs,
                ]
            )
            rowId = db.lastInsertedRowID
        }

        try writeImages(pass.images, passId: rowId, db)
        try writeLocales(pass.locales, passId: rowId, db)
        return PassRecordId(rowId)
    }

    /// Deletes the row (and, via `ON DELETE CASCADE`, its image/locale children). Returns
    /// `false` if no row matched, so the repository can surface `.integrityViolation`.
    static func delete(byId id: PassRecordId, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM \(Schema.Tables.passes) WHERE id = ?",
            arguments: [id.value]
        )
        return db.changesCount > 0
    }

    /// Sets or clears (`nil` -> SQL NULL) the `user_label` column on the row matching `id`.
    /// Deliberately does not touch `updated_at` — the signed pass content is unchanged.
    /// Returns `false` if no row matched, so the repository can surface `.integrityViolation`.
    static func updateUserLabel(id: PassRecordId, label: String?, _ db: Database) throws -> Bool {
        try db.execute(
            sql: "UPDATE \(Schema.Tables.passes) SET user_label = ? WHERE id = ?",
            arguments: [label, id.value]
        )
        return db.changesCount > 0
    }

    // MARK: - Row mapping

    private static func summary(from row: Row) -> PassSummary? {
        guard
            let type = PassType(dbValue: row["type"]),
            let kind = SignatureStatusKind(dbValue: row["signature_status_kind"])
        else { return nil }
        let expiration: Int64? = row["expiration_epoch_ms"]
        return PassSummary(
            id: PassRecordId(row["id"]),
            type: type,
            serialNumber: row["serial_number"],
            organizationName: row["organization_name"],
            description: row["description"],
            expirationDate: expiration.map(PassInstant.init(epochMillis:)),
            voided: (row["voided"] as Int64) != 0,
            signatureStatus: SignatureStatus(kind: kind),
            createdAt: PassInstant(epochMillis: row["created_at_epoch_ms"]),
            updatedAt: PassInstant(epochMillis: row["updated_at_epoch_ms"]),
            userLabel: row["user_label"]
        )
    }

    // MARK: - Children

    private static func readImages(passId: PassRecordId, _ db: Database) throws -> [ImageRole: ImageBytes] {
        var out: [ImageRole: ImageBytes] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT role, bytes FROM \(Schema.Tables.passImages) WHERE pass_id = ?",
            arguments: [passId.value]
        ) {
            guard let role = ImageRole(dbValue: row["role"]) else { continue }
            out[role] = ImageBytes(bytes: row["bytes"])
        }
        return out
    }

    private static func writeImages(_ images: [ImageRole: ImageBytes], passId: Int64, _ db: Database) throws {
        for (role, image) in images {
            try db.execute(
                sql: "INSERT INTO \(Schema.Tables.passImages) (pass_id, role, bytes) VALUES (?, ?, ?)",
                arguments: [passId, role.dbValue, image.bytes]
            )
        }
    }

    private static func readLocales(passId: PassRecordId, _ db: Database) throws -> [PassLocale: LocalizedStrings] {
        var out: [PassLocale: LocalizedStrings] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT locale_tag, strings_json FROM \(Schema.Tables.passLocales) WHERE pass_id = ?",
            arguments: [passId.value]
        ) {
            out[PassLocale(row["locale_tag"])] = try PassBlob.decodeStrings(row["strings_json"])
        }
        return out
    }

    private static func writeLocales(_ locales: [PassLocale: LocalizedStrings], passId: Int64, _ db: Database) throws {
        for (locale, strings) in locales {
            try db.execute(
                sql: "INSERT INTO \(Schema.Tables.passLocales) (pass_id, locale_tag, strings_json) VALUES (?, ?, ?)",
                arguments: [passId, locale.tag, try PassBlob.encodeStrings(strings)]
            )
        }
    }
}

extension ImageRole {
    /// Stored in the `pass_images.role` column.
    var dbValue: String {
        switch self {
        case .logo: return "logo"
        case .logoRetina: return "logoRetina"
        case .logoSuperRetina: return "logoSuperRetina"
        case .icon: return "icon"
        case .iconRetina: return "iconRetina"
        case .iconSuperRetina: return "iconSuperRetina"
        case .strip: return "strip"
        case .stripRetina: return "stripRetina"
        case .stripSuperRetina: return "stripSuperRetina"
        case .background: return "background"
        case .backgroundRetina: return "backgroundRetina"
        case .backgroundSuperRetina: return "backgroundSuperRetina"
        case .thumbnail: return "thumbnail"
        case .thumbnailRetina: return "thumbnailRetina"
        case .thumbnailSuperRetina: return "thumbnailSuperRetina"
        case .footer: return "footer"
        case .footerRetina: return "footerRetina"
        case .footerSuperRetina: return "footerSuperRetina"
        }
    }

    init?(dbValue: String) {
        guard let match = ImageRole.allCases.first(where: { $0.dbValue == dbValue }) else { return nil }
        self = match
    }
}
