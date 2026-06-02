import Foundation
import PassesCore

/// JSON codec for the `passes.pass_json` BLOB and the `pass_locales.strings_json` BLOB.
/// Mirrors Android's `internal/PassJson.kt` (`PassJsonCodec`): the blob carries every `Pass`
/// field EXCEPT `images` and `locales`, which live in their own tables (`pass_images`,
/// `pass_locales`) and are re-attached on load. Encoding them here too would duplicate the
/// bytes on disk.
///
/// The on-disk shape is a private `Codable` DTO, so the public `Pass` model needs no
/// `Codable` conformance and the storage format can evolve independently of the entity.
/// iOS passes databases never cross to Android, so byte parity with Android's encoding is
/// unnecessary — only self-consistency (encode then decode round-trips) matters.
enum PassBlob {
    static func encode(_ pass: Pass) throws -> Data {
        try JSONEncoder().encode(DTO(pass))
    }

    /// Decodes the blob into a `Pass` whose `images`/`locales` are empty; the caller
    /// re-attaches them from the child tables.
    static func decode(_ data: Data) throws -> Pass {
        try JSONDecoder().decode(DTO.self, from: data).toPass()
    }

    static func encodeStrings(_ strings: LocalizedStrings) throws -> Data {
        try JSONEncoder().encode(strings.entries)
    }

    static func decodeStrings(_ data: Data) throws -> LocalizedStrings {
        LocalizedStrings(entries: try JSONDecoder().decode([String: String].self, from: data))
    }

    // MARK: - DTO

    private struct DTO: Codable {
        var type: String
        var serialNumber: String
        var description: String
        var organizationName: String
        var expirationEpochMs: Int64?
        var voided: Bool
        var foreground: Int32?
        var background: Int32?
        var label: Int32?
        var header: [FieldDTO]
        var primary: [FieldDTO]
        var secondary: [FieldDTO]
        var auxiliary: [FieldDTO]
        var backFields: [FieldDTO]
        var barcode: BarcodeDTO?

        init(_ pass: Pass) {
            type = pass.type.dbValue
            serialNumber = pass.serialNumber
            description = pass.description
            organizationName = pass.organizationName
            expirationEpochMs = pass.expirationDate?.epochMillis
            voided = pass.voided
            foreground = pass.colors.foreground?.rgb
            background = pass.colors.background?.rgb
            label = pass.colors.label?.rgb
            header = pass.frontFields.header.map(FieldDTO.init)
            primary = pass.frontFields.primary.map(FieldDTO.init)
            secondary = pass.frontFields.secondary.map(FieldDTO.init)
            auxiliary = pass.frontFields.auxiliary.map(FieldDTO.init)
            backFields = pass.backFields.map(FieldDTO.init)
            barcode = pass.barcode.map(BarcodeDTO.init)
        }

        func toPass() -> Pass {
            Pass(
                type: PassType(dbValue: type) ?? .generic,
                serialNumber: serialNumber,
                description: description,
                organizationName: organizationName,
                expirationDate: expirationEpochMs.map(PassInstant.init(epochMillis:)),
                voided: voided,
                colors: PassColors(
                    foreground: foreground.map(ColorValue.init(rgb:)),
                    background: background.map(ColorValue.init(rgb:)),
                    label: label.map(ColorValue.init(rgb:))
                ),
                frontFields: PassFields(
                    header: header.map(\.toField),
                    primary: primary.map(\.toField),
                    secondary: secondary.map(\.toField),
                    auxiliary: auxiliary.map(\.toField)
                ),
                backFields: backFields.map(\.toField),
                barcode: barcode?.toBarcode
            )
        }
    }

    private struct FieldDTO: Codable {
        var key: String
        var label: String?
        var value: String
        var textAlignment: String

        init(_ field: PassField) {
            key = field.key
            label = field.label
            value = field.value
            textAlignment = field.textAlignment.dbValue
        }

        var toField: PassField {
            PassField(
                key: key,
                label: label,
                value: value,
                textAlignment: TextAlignment(dbValue: textAlignment) ?? .natural
            )
        }
    }

    private struct BarcodeDTO: Codable {
        var format: String
        var message: String
        var messageEncoding: String
        var altText: String?

        init(_ barcode: Barcode) {
            format = barcode.format.dbValue
            message = barcode.message
            messageEncoding = barcode.messageEncoding
            altText = barcode.altText
        }

        var toBarcode: Barcode {
            Barcode(
                format: BarcodeFormat(dbValue: format) ?? .qr,
                message: message,
                messageEncoding: messageEncoding,
                altText: altText
            )
        }
    }
}

// MARK: - Stable string encodings for the enums that hit indexed columns / the blob.

extension PassType {
    /// Stored in the indexed `passes.type` column and the blob. Explicit switch (not
    /// `String(describing:)`) so a future case rename is a compile error, not silent
    /// on-disk drift.
    var dbValue: String {
        switch self {
        case .boardingPass: return "boardingPass"
        case .eventTicket: return "eventTicket"
        case .coupon: return "coupon"
        case .storeCard: return "storeCard"
        case .generic: return "generic"
        }
    }

    init?(dbValue: String) {
        switch dbValue {
        case "boardingPass": self = .boardingPass
        case "eventTicket": self = .eventTicket
        case "coupon": self = .coupon
        case "storeCard": self = .storeCard
        case "generic": self = .generic
        default: return nil
        }
    }
}

extension SignatureStatusKind {
    /// Stored in the `passes.signature_status_kind` column.
    var dbValue: String {
        switch self {
        case .unsigned: return "unsigned"
        case .selfSigned: return "selfSigned"
        case .appleVerified: return "appleVerified"
        case .certChainIncomplete: return "certChainIncomplete"
        }
    }

    init?(dbValue: String) {
        switch dbValue {
        case "unsigned": self = .unsigned
        case "selfSigned": self = .selfSigned
        case "appleVerified": self = .appleVerified
        case "certChainIncomplete": self = .certChainIncomplete
        default: return nil
        }
    }
}

extension SignatureStatus {
    /// Rebuilds a `SignatureStatus` from the stored kind. The kind enum has no associated
    /// values, so this is total.
    init(kind: SignatureStatusKind) {
        switch kind {
        case .unsigned: self = .unsigned
        case .selfSigned: self = .selfSigned
        case .appleVerified: self = .appleVerified
        case .certChainIncomplete: self = .certChainIncomplete
        }
    }
}

extension TextAlignment {
    var dbValue: String {
        switch self {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case .natural: return "natural"
        }
    }

    init?(dbValue: String) {
        switch dbValue {
        case "left": self = .left
        case "center": self = .center
        case "right": self = .right
        case "natural": self = .natural
        default: return nil
        }
    }
}

extension BarcodeFormat {
    var dbValue: String {
        switch self {
        case .qr: return "qr"
        case .pdf417: return "pdf417"
        case .aztec: return "aztec"
        case .code128: return "code128"
        }
    }

    init?(dbValue: String) {
        switch dbValue {
        case "qr": self = .qr
        case "pdf417": self = .pdf417
        case "aztec": self = .aztec
        case "code128": self = .code128
        default: return nil
        }
    }
}
