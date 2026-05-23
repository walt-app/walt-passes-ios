import Foundation

/// A parsed PKPASS pass. All security-critical normalization (signature verification, hash
/// checks, resource-limit enforcement) has already happened by the time a `Pass` exists; the
/// surrounding `SignatureStatus` tells the caller what level of provenance the underlying
/// archive carried.
///
/// Field-level content (label/value strings, organization name, etc.) is sourced from the
/// default locale variant of the archive. Localized variants are retained verbatim in `locales`
/// so the renderer can re-bind on locale change without re-parsing.
public struct Pass: Sendable, Equatable {
    public let type: PassType
    public let serialNumber: String
    public let description: String
    public let organizationName: String
    public let expirationDate: PassInstant?
    public let voided: Bool
    public let colors: PassColors
    public let frontFields: PassFields
    public let backFields: [PassField]
    public let barcode: Barcode?
    public let images: [ImageRole: ImageBytes]
    public let locales: [PassLocale: LocalizedStrings]

    public init(
        type: PassType,
        serialNumber: String,
        description: String,
        organizationName: String,
        expirationDate: PassInstant? = nil,
        voided: Bool = false,
        colors: PassColors,
        frontFields: PassFields,
        backFields: [PassField],
        barcode: Barcode? = nil,
        images: [ImageRole: ImageBytes] = [:],
        locales: [PassLocale: LocalizedStrings] = [:]
    ) {
        self.type = type
        self.serialNumber = serialNumber
        self.description = description
        self.organizationName = organizationName
        self.expirationDate = expirationDate
        self.voided = voided
        self.colors = colors
        self.frontFields = frontFields
        self.backFields = backFields
        self.barcode = barcode
        self.images = images
        self.locales = locales
    }
}

/// Wrapper around the raw bytes of a single pass image. Exists so the surrounding `Pass`
/// gets a sane `Equatable`: `Data` already supports value equality in Swift, but wrapping
/// it preserves the Android contract (where the wrapper exists because `ByteArray` has
/// reference equality) and gives callers an opaque handle that signals "image bytes, do
/// not do arithmetic on this."
public struct ImageBytes: Sendable, Equatable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

/// RGB color triplet sourced from the pass.json `foregroundColor` / `backgroundColor` /
/// `labelColor` fields. The parser normalizes both `rgb(R,G,B)` and `#RRGGBB` forms into a
/// single 24-bit packed integer before producing this value.
public struct ColorValue: Sendable, Equatable, Hashable {
    public let rgb: Int32

    public init(rgb: Int32) {
        self.rgb = rgb
    }
}

public struct PassColors: Sendable, Equatable {
    public let foreground: ColorValue?
    public let background: ColorValue?
    public let label: ColorValue?

    public init(
        foreground: ColorValue? = nil,
        background: ColorValue? = nil,
        label: ColorValue? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.label = label
    }
}

/// The four field rows that appear on the front of a pass. PKPASS does not require any
/// particular row to be populated; renderers must tolerate empty lists.
public struct PassFields: Sendable, Equatable {
    public let header: [PassField]
    public let primary: [PassField]
    public let secondary: [PassField]
    public let auxiliary: [PassField]

    public init(
        header: [PassField] = [],
        primary: [PassField] = [],
        secondary: [PassField] = [],
        auxiliary: [PassField] = []
    ) {
        self.header = header
        self.primary = primary
        self.secondary = secondary
        self.auxiliary = auxiliary
    }
}

public struct PassField: Sendable, Equatable {
    public let key: String
    public let label: String?
    public let value: String
    public let textAlignment: TextAlignment

    public init(
        key: String,
        label: String? = nil,
        value: String,
        textAlignment: TextAlignment = .natural
    ) {
        self.key = key
        self.label = label
        self.value = value
        self.textAlignment = textAlignment
    }
}

public enum TextAlignment: Sendable, CaseIterable {
    case left
    case center
    case right
    case natural
}

public struct Barcode: Sendable, Equatable {
    public let format: BarcodeFormat
    public let message: String
    public let messageEncoding: String
    public let altText: String?

    public init(
        format: BarcodeFormat,
        message: String,
        messageEncoding: String,
        altText: String? = nil
    ) {
        self.format = format
        self.message = message
        self.messageEncoding = messageEncoding
        self.altText = altText
    }
}

/// The PKPASS-pass barcode enum. Deliberately distinct from `ScannableFormat` — a verified
/// PKPASS barcode and a user-typed card barcode are different trust artifacts that happen to
/// share a rendering technology.
public enum BarcodeFormat: Sendable, CaseIterable {
    case qr
    case pdf417
    case aztec
    case code128
}

/// The asset roles PKPASS recognises. `retina` and `superRetina` are the @2x / @3x variants;
/// the parser preserves whichever variants the archive provides without upscaling.
public enum ImageRole: Sendable, Hashable, CaseIterable {
    case logo
    case logoRetina
    case logoSuperRetina
    case icon
    case iconRetina
    case iconSuperRetina
    case strip
    case stripRetina
    case stripSuperRetina
    case background
    case backgroundRetina
    case backgroundSuperRetina
    case thumbnail
    case thumbnailRetina
    case thumbnailSuperRetina
    case footer
    case footerRetina
    case footerSuperRetina
}

/// Contents of a single `<locale>.lproj/pass.strings` file.
public struct LocalizedStrings: Sendable, Equatable {
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    /// Empty strings table. Used as the no-op fallback when a pass carries no locales.
    public static let empty = LocalizedStrings(entries: [:])

    /// Looks `raw` up in this strings table; if absent, returns `raw` unchanged. This is
    /// Apple's documented PKPASS behavior for `label`, `value`, `attributedValue`, and
    /// `organizationName`: the field's literal text is treated as the lookup key, and a
    /// miss falls through to the raw text.
    ///
    /// The "fall through to raw" path is what makes the substitution idempotent and makes
    /// dynamic field values (ticket numbers, dates, codes) safe to pipe through this
    /// function: they will not match any key and emerge unchanged.
    public func lookupOrSelf(_ raw: String) -> String {
        entries[raw] ?? raw
    }

    /// Nullable overload of `lookupOrSelf`. Returns `nil` only when `raw` is `nil`; for
    /// present values, behaves exactly like the non-nullable form. Exists so callers
    /// holding an optional `PassField.label` do not have to lift the nil-check themselves.
    public func lookupOrSelf(_ raw: String?) -> String? {
        raw.map { lookupOrSelf($0) }
    }
}

/// BCP-47 language tag, e.g. `en-US`, `de`, `zh-Hant`. Parsing of the tag itself is left to
/// the consumer module that knows the platform's locale APIs; PassesCore is pure Swift and
/// does not depend on `Foundation.Locale` for KMP/Android-parity reasons.
public struct PassLocale: Sendable, Equatable, Hashable {
    public let tag: String

    public init(_ tag: String) {
        self.tag = tag
    }
}

extension Pass {
    /// Resolves a `LocalizedStrings` from this pass's `locales` for `preferred`, using
    /// Apple's documented PKPASS locale-fallback chain:
    ///
    ///  1. Exact tag match (`en-US` finds `en-US.lproj`).
    ///  2. Language-only fallback (`en-US` -> `en`, `sv-FI` -> `sv`). The split point is
    ///     either `-` (BCP 47) or `_` (legacy locale form), whichever the consumer hands in.
    ///  3. The `en` table, when present. Apple treats English as the implicit project fallback.
    ///  4. The locale with the lexicographically-smallest tag. PKPASS does not pin a
    ///     "default" locale; sorting deterministically (rather than relying on map
    ///     iteration order) gives the consumer *some* localized substitution rather than
    ///     reverting every label to its raw key.
    ///  5. `LocalizedStrings.empty` when the pass has no `.lproj/pass.strings` at all.
    ///
    /// Pure function: PassesCore never reads the device locale itself.
    public func resolveLocalizedStrings(preferred: PassLocale) -> LocalizedStrings {
        if locales.isEmpty { return .empty }
        // Split on `-` first, then `_`, mirroring Android's substringBefore chain.
        let language = String(preferred.tag.prefix { $0 != "-" }).prefix { $0 != "_" }
        let languageString = String(language)
        let languageFallback: LocalizedStrings? = {
            guard !languageString.isEmpty, languageString != preferred.tag else { return nil }
            return locales[PassLocale(languageString)]
        }()
        let deterministicFallback = locales.min(by: { $0.key.tag < $1.key.tag })?.value
        return locales[preferred]
            ?? languageFallback
            ?? locales[PassLocale("en")]
            ?? deterministicFallback
            ?? .empty
    }
}

/// Epoch-millisecond timestamp. Avoids depending on `Foundation.Date` directly so the type
/// matches Android's `PassInstant` shape verbatim, keeping cross-platform diffs syntactic
/// rather than semantic.
public struct PassInstant: Sendable, Equatable, Hashable {
    public let epochMillis: Int64

    public init(epochMillis: Int64) {
        self.epochMillis = epochMillis
    }
}
