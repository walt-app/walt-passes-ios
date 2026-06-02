import Foundation

/// Outcome of running `decodePassJson` over the entries map produced by `extractSafely`.
/// Internal only; the parser-glue layer lifts a `failed` into the right `ParseResult` arm. The
/// `Ok.pass` is built with `images = [:]` and `locales = [:]` - those come from other archive
/// entries and are wired in by the glue layer.
internal enum PassJsonDecodeResult: Equatable {
    case ok(Pass)
    case failed(PassJsonFailure)
}

/// Why `decodePassJson` rejected a `pass.json` payload. Arms are finer-grained than the public
/// `MalformedReason` / `UnsupportedReason` surface so the glue layer routes each independently.
internal enum PassJsonFailure: Equatable {
    case missing
    case invalidJson
    case invalidShape
    case jsonDepthExceeded
    case jsonStringTooLong
    case unknownFormatVersion(version: Int)
    case unknownPassStyle(raw: String)
}

/// Deserializes `pass.json` into the subset of `Pass` that pass.json owns. Pure function.
///
/// Three layers run in order, earliest-firing wins:
///  1. Missing-entry check -> `missing`.
///  2. Pre-pass tokenizer (`enforceJsonLimits`) -> enforces `maxJsonDepth` / `maxJsonStringBytes`
///     before `JSONSerialization` allocates; post-validating a parsed tree is too late.
///  3. `JSONSerialization` parse + structural mapping. JSONSerialization is non-lenient by
///     default (rejects unquoted keys / single quotes -> `invalidJson`); unknown keys are
///     ignored, so PKPASS spec additions do not break consumers.
///
/// **Dangerous fields.** `nfc`, `webServiceURL`, `authenticationToken`, `personalization`, and
/// `personalizationToken` are intentionally not surfaced on `Pass`: parsed (so they cannot trip
/// a parse failure) but discarded (no field exists to render or transmit them). The "parsed and
/// dropped" shape is structural - there are simply no fields on `Pass` for them.
internal func decodePassJson(_ entries: [(name: String, bytes: [UInt8])], config: ParserConfig) -> PassJsonDecodeResult {
    let byName = Dictionary(entries.map { ($0.name, $0.bytes) }, uniquingKeysWith: { first, _ in first })
    guard let bytes = byName[PASS_JSON_FILE_NAME] else {
        return .failed(.missing)
    }
    if let limitFailure = enforceJsonLimits(bytes, config: config) {
        return .failed(limitFailure)
    }
    return parseAndMap(bytes)
}

private func parseAndMap(_ bytes: [UInt8]) -> PassJsonDecodeResult {
    guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
        return .failed(.invalidJson)
    }
    let orderedKeys = orderedTopLevelJsonKeys(bytes, fallback: Array(root.keys))
    if let versionFailure = checkVersion(root) {
        return .failed(versionFailure)
    }
    return resolveAndAssemble(root, orderedKeys: orderedKeys)
}

private func checkVersion(_ root: [String: Any]) -> PassJsonFailure? {
    let version = (root[FIELD_FORMAT_VERSION] as? NSNumber).flatMap { intExact($0) }
    return version == PKPASS_FORMAT_VERSION ? nil : .unknownFormatVersion(version: version ?? 0)
}

private func resolveAndAssemble(_ root: [String: Any], orderedKeys: [String]) -> PassJsonDecodeResult {
    switch resolveStyle(root, orderedKeys: orderedKeys) {
    case .multiple:
        return .failed(.invalidShape)
    case .unknown(let raw):
        return .failed(.unknownPassStyle(raw: raw))
    case .found(let type, let node):
        if let pass = assemblePass(root, type: type, node: node) {
            return .ok(pass)
        }
        return .failed(.invalidShape)
    }
}

private func assemblePass(_ root: [String: Any], type: PassType, node: [String: Any]) -> Pass? {
    let expiration = parseExpiration(root[FIELD_EXPIRATION_DATE])
    guard let requireds = readRequiredFields(root), expiration != .malformed else { return nil }
    let instant: PassInstant?
    if case .ok(let value) = expiration { instant = value } else { instant = nil }
    return Pass(
        type: type,
        serialNumber: requireds.serial,
        description: requireds.description,
        organizationName: requireds.organization,
        expirationDate: instant,
        voided: (root[FIELD_VOIDED] as? NSNumber)?.boolValue ?? false,
        colors: PassColors(
            foreground: parseColor(stringField(root, FIELD_FOREGROUND_COLOR)),
            background: parseColor(stringField(root, FIELD_BACKGROUND_COLOR)),
            label: parseColor(stringField(root, FIELD_LABEL_COLOR))
        ),
        frontFields: PassFields(
            header: parseFieldList(node[FIELD_HEADER_FIELDS]),
            primary: parseFieldList(node[FIELD_PRIMARY_FIELDS]),
            secondary: parseFieldList(node[FIELD_SECONDARY_FIELDS]),
            auxiliary: parseFieldList(node[FIELD_AUXILIARY_FIELDS])
        ),
        backFields: parseFieldList(node[FIELD_BACK_FIELDS]),
        barcode: parseBarcode(root),
        images: [:],
        locales: [:]
    )
}

private struct RequiredFields {
    let serial: String
    let description: String
    let organization: String
}

private func readRequiredFields(_ root: [String: Any]) -> RequiredFields? {
    guard let serial = stringField(root, FIELD_SERIAL_NUMBER),
        let description = stringField(root, FIELD_DESCRIPTION),
        let organization = stringField(root, FIELD_ORGANIZATION_NAME)
    else { return nil }
    return RequiredFields(serial: serial, description: description, organization: organization)
}

private enum StyleResolution {
    case found(type: PassType, node: [String: Any])
    case unknown(raw: String)
    case multiple
}

/// Resolves the declared style with its sub-object, or a reason it could not. In the no-style
/// branch the first object-valued top-level key not on the known-style or known-non-style
/// allowlist is the unknown-style hint, in source-key order for stable reporting.
private func resolveStyle(_ root: [String: Any], orderedKeys: [String]) -> StyleResolution {
    let present = STYLE_KEYS_IN_ORDER.filter { root[$0.key] is [String: Any] }
    if present.count == 1 {
        let entry = present[0]
        return .found(type: entry.value, node: root[entry.key] as! [String: Any])
    }
    if present.count > 1 {
        return .multiple
    }
    for key in orderedKeys {
        let isStyleCandidate =
            root[key] is [String: Any]
            && STYLE_KEY_TO_TYPE[key] == nil
            && !KNOWN_NON_STYLE_OBJECT_KEYS.contains(key)
        if isStyleCandidate { return .unknown(raw: key) }
    }
    return .unknown(raw: "")
}

private enum ExpirationParse: Equatable {
    case absent
    case malformed
    case ok(PassInstant)
}

/// Three-state expiration parse: distinguishes "absent" from "present-but-malformed" so
/// `assemblePass` can fail an unparseable `expirationDate` as `invalidShape` rather than silently
/// dropping a security-relevant validity window.
private func parseExpiration(_ probe: Any?) -> ExpirationParse {
    guard let probe, !(probe is NSNull) else { return .absent }
    guard let text = probe as? String else { return .malformed }
    if let millis = parseIso8601Millis(text) {
        return .ok(PassInstant(epochMillis: millis))
    }
    return .malformed
}

/// Parses an ISO-8601 timestamp to epoch millis. Mirrors Android's `OffsetDateTime.parse`: tries
/// with and without fractional seconds. Returns `nil` on any unparseable input.
private func parseIso8601Millis(_ text: String) -> Int64? {
    // Formatters are constructed per call rather than cached: ISO8601DateFormatter is not
    // Sendable, and parse is documented to run off-main on any thread.
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    for formatter in [withFractional, plain] {
        if let date = formatter.date(from: text) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
    }
    return nil
}

/// Accepts both `rgb(R,G,B)` and `#RRGGBB`. Returns `nil` for `nil` input or any unrecognized
/// form so callers default to "no color set" without try/catch.
private func parseColor(_ text: String?) -> ColorValue? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespaces) else { return nil }
    if let rgb = matchRgb(trimmed) { return rgb }
    return matchHex(trimmed)
}

private func matchRgb(_ text: String) -> ColorValue? {
    guard let match = RGB_REGEX.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        match.range.length == text.utf16.count
    else { return nil }
    func component(_ i: Int) -> Int? {
        guard let range = Range(match.range(at: i), in: text) else { return nil }
        return Int(text[range]).flatMap { (0...MAX_COLOR_COMPONENT).contains($0) ? $0 : nil }
    }
    guard let r = component(1), let g = component(2), let b = component(3) else { return nil }
    return ColorValue(rgb: Int32((r << RED_SHIFT) | (g << GREEN_SHIFT) | b))
}

private func matchHex(_ text: String) -> ColorValue? {
    guard let match = HEX_REGEX.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        match.range.length == text.utf16.count,
        let range = Range(match.range(at: 1), in: text),
        let value = Int(text[range], radix: HEX_RADIX)
    else { return nil }
    return ColorValue(rgb: Int32(value))
}

private func parseFieldList(_ node: Any?) -> [PassField] {
    guard let array = node as? [Any] else { return [] }
    return array.compactMap { element -> PassField? in
        guard let obj = element as? [String: Any],
            let key = stringField(obj, FIELD_KEY),
            let value = primitiveString(obj[FIELD_VALUE])
        else { return nil }
        let alignment = stringField(obj, FIELD_TEXT_ALIGNMENT).flatMap { TEXT_ALIGNMENT_MAP[$0] } ?? .natural
        return PassField(key: key, label: stringField(obj, FIELD_LABEL), value: value, textAlignment: alignment)
    }
}

/// Prefers the modern `barcodes[0]` over the legacy `barcode` scalar. A barcode entry that fails
/// to map is dropped so a single bad entry does not kill the pass; the legacy scalar is the
/// fallback. If neither resolves, `barcode = nil`.
private func parseBarcode(_ root: [String: Any]) -> Barcode? {
    if let array = root[FIELD_BARCODES] as? [Any] {
        for element in array {
            if let obj = element as? [String: Any], let barcode = parseBarcodeNode(obj) {
                return barcode
            }
        }
    }
    if let obj = root[FIELD_BARCODE] as? [String: Any] {
        return parseBarcodeNode(obj)
    }
    return nil
}

private func parseBarcodeNode(_ node: [String: Any]) -> Barcode? {
    guard let format = stringField(node, FIELD_FORMAT).flatMap({ BARCODE_FORMAT_MAP[$0] }),
        let message = stringField(node, FIELD_MESSAGE),
        let encoding = stringField(node, FIELD_MESSAGE_ENCODING)
    else { return nil }
    return Barcode(format: format, message: message, messageEncoding: encoding, altText: stringField(node, FIELD_ALT_TEXT))
}

/// String-valued field, `nil` if absent or non-string. JSONSerialization decodes a JSON bool as
/// an NSNumber, so `as? String` correctly rejects it.
private func stringField(_ obj: [String: Any], _ name: String) -> String? {
    obj[name] as? String
}

/// A field `value` may be a string or a number in real passes; mirror Android's `JsonPrimitive
/// .content`, which stringifies either. A bool / object / array / null yields `nil`.
private func primitiveString(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let n = value as? NSNumber {
        // Reject booleans (NSNumber bridges them); only true numbers stringify.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.stringValue
    }
    return nil
}

private func intExact(_ number: NSNumber) -> Int? {
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    let d = number.doubleValue
    return d == d.rounded() ? number.intValue : nil
}

/// Recovers top-level object keys in source order. JSONSerialization gives an unordered dict, so
/// scan the raw bytes for the first occurrence of each key for deterministic unknown-style
/// reporting. Falls back to the dict's keys if scanning misses any.
private func orderedTopLevelJsonKeys(_ bytes: [UInt8], fallback: [String]) -> [String] {
    guard let text = String(bytes: bytes, encoding: .utf8) else { return fallback }
    return fallback
        .map { key -> (key: String, pos: Int) in
            if let range = text.range(of: "\"\(key)\"") {
                return (key, text.distance(from: text.startIndex, to: range.lowerBound))
            }
            return (key, Int.max)
        }
        .sorted { $0.pos < $1.pos }
        .map(\.key)
}

private let STYLE_KEY_TO_TYPE: [String: PassType] = [
    "boardingPass": .boardingPass,
    "eventTicket": .eventTicket,
    "coupon": .coupon,
    "storeCard": .storeCard,
    "generic": .generic,
]

private let STYLE_KEYS_IN_ORDER: [(key: String, value: PassType)] = [
    ("boardingPass", .boardingPass),
    ("eventTicket", .eventTicket),
    ("coupon", .coupon),
    ("storeCard", .storeCard),
    ("generic", .generic),
]

private let KNOWN_NON_STYLE_OBJECT_KEYS: Set<String> = [
    "nfc", "personalization", "personalizationToken", "userInfo", "semantics", "barcode",
]

private let BARCODE_FORMAT_MAP: [String: BarcodeFormat] = [
    "PKBarcodeFormatQR": .qr,
    "PKBarcodeFormatPDF417": .pdf417,
    "PKBarcodeFormatAztec": .aztec,
    "PKBarcodeFormatCode128": .code128,
]

private let TEXT_ALIGNMENT_MAP: [String: TextAlignment] = [
    "PKTextAlignmentLeft": .left,
    "PKTextAlignmentCenter": .center,
    "PKTextAlignmentRight": .right,
    "PKTextAlignmentNatural": .natural,
]

// swiftlint:disable:next force_try
private let RGB_REGEX = try! NSRegularExpression(pattern: #"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)"#)
// swiftlint:disable:next force_try
private let HEX_REGEX = try! NSRegularExpression(pattern: "#([0-9a-fA-F]{6})")

private let PKPASS_FORMAT_VERSION = 1
private let MAX_COLOR_COMPONENT = 255
private let RED_SHIFT = 16
private let GREEN_SHIFT = 8
private let HEX_RADIX = 16

private let FIELD_FORMAT_VERSION = "formatVersion"
private let FIELD_SERIAL_NUMBER = "serialNumber"
private let FIELD_DESCRIPTION = "description"
private let FIELD_ORGANIZATION_NAME = "organizationName"
private let FIELD_EXPIRATION_DATE = "expirationDate"
private let FIELD_VOIDED = "voided"
private let FIELD_FOREGROUND_COLOR = "foregroundColor"
private let FIELD_BACKGROUND_COLOR = "backgroundColor"
private let FIELD_LABEL_COLOR = "labelColor"
private let FIELD_HEADER_FIELDS = "headerFields"
private let FIELD_PRIMARY_FIELDS = "primaryFields"
private let FIELD_SECONDARY_FIELDS = "secondaryFields"
private let FIELD_AUXILIARY_FIELDS = "auxiliaryFields"
private let FIELD_BACK_FIELDS = "backFields"
private let FIELD_KEY = "key"
private let FIELD_VALUE = "value"
private let FIELD_LABEL = "label"
private let FIELD_TEXT_ALIGNMENT = "textAlignment"
private let FIELD_BARCODE = "barcode"
private let FIELD_BARCODES = "barcodes"
private let FIELD_FORMAT = "format"
private let FIELD_MESSAGE = "message"
private let FIELD_MESSAGE_ENCODING = "messageEncoding"
private let FIELD_ALT_TEXT = "altText"
