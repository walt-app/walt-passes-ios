import Foundation

/// Outcome of running `parseStrings` over a single `<locale>.lproj/pass.strings` payload.
/// Internal only; the parser-glue layer lifts a `failed` into the right `ParseResult` arm.
internal enum StringsResult: Equatable {
    case ok(LocalizedStrings)
    case failed(StringsFailure)
}

/// Why `parseStrings` rejected a payload. All arms except `valueTooLong` lift to
/// `MalformedReason.invalidStrings`; `valueTooLong` lifts to `resourceLimitExceeded(.jsonStringSize)`.
internal enum StringsFailure: Error, Equatable {
    case invalidEncoding
    case unterminatedString
    case unterminatedComment
    case badStructure
    case badEscape
    case valueTooLong
}

/// Parses a single Apple .strings localization payload into a `LocalizedStrings`. Pure function:
/// iteration order matches source order, duplicate keys are last-write-wins (matching Apple).
///
/// Three layers run in order, earliest-firing wins:
///  1. Charset BOM-sniff and strict decode - UTF-16 LE/BE or UTF-8 BOM signs the file, else
///     UTF-8 is the documented default. A non-UTF-8 sequence with no BOM fails as
///     `invalidEncoding` rather than yielding replacement characters.
///  2. Hand-rolled lexer - single-pass walker with explicit in-string / in-comment state.
///     Handles Apple's `\Uxxxx` (4 hex digits, not a 21-bit codepoint), supplementary-plane
///     `\Uxxxx\Uxxxx` surrogate pairs, non-nesting block comments, and the rule that a
///     backslash before EOL is not a line continuation.
///  3. Per-value byte cap - `maxJsonStringBytes` applies to each decoded value (UTF-8 byte
///     equivalent, conservatively summed per code unit so an oversized value is rejected mid-read).
/// The cap is applied to values only, not keys: keys are dotted identifiers that routinely
/// exceed any sensible value cap; the cap bounds rendered-surface memory, not key length.
internal func parseStrings(_ bytes: [UInt8], config: ParserConfig) -> StringsResult {
    guard let text = decodeWithBomSniff(bytes) else {
        return .failed(.invalidEncoding)
    }
    do {
        let strings = try StringsLexer(text, maxValueBytes: config.maxJsonStringBytes).parse()
        return .ok(strings)
    } catch let failure as StringsFailure {
        return .failed(failure)
    } catch {
        return .failed(.invalidEncoding)
    }
}

/// BOM-sniffs the leading bytes for UTF-16 LE/BE / UTF-8 and decodes the rest strictly. Returns
/// `nil` if decoding fails. UTF-8 is the no-BOM default per Apple's documented behavior. The BOM
/// is stripped before decoding so it does not surface as a spurious U+FEFF first character.
///
/// `String(data:encoding:)` returns `nil` on invalid UTF-8, which is the strict-decode posture
/// Android gets from a `CodingErrorAction.REPORT` decoder.
private func decodeWithBomSniff(_ bytes: [UInt8]) -> String? {
    let (encoding, skip): (String.Encoding, Int)
    if hasPrefix(bytes, BOM_UTF8) {
        (encoding, skip) = (.utf8, BOM_UTF8.count)
    } else if hasPrefix(bytes, BOM_UTF16BE) {
        (encoding, skip) = (.utf16BigEndian, BOM_UTF16BE.count)
    } else if hasPrefix(bytes, BOM_UTF16LE) {
        (encoding, skip) = (.utf16LittleEndian, BOM_UTF16LE.count)
    } else {
        (encoding, skip) = (.utf8, 0)
    }
    let payload = Data(bytes[skip...])
    return String(data: payload, encoding: encoding)
}

private func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
    guard bytes.count >= prefix.count else { return false }
    return Array(bytes[0..<prefix.count]) == prefix
}

/// Conservative UTF-8 byte count for a single UTF-16 code unit. Surrogate halves count as 3
/// bytes each - a real surrogate-pair codepoint encodes to 4 UTF-8 bytes, so this overcounts by
/// 2 for a supplementary-plane character. The overcount is deliberate: this guards "is this
/// string under the cap," and a conservative upper bound never lets an over-budget string
/// through. Not suitable for serialization sizing.
private func utf8Bytes(_ codeUnit: UInt16) -> Int {
    let code = Int(codeUnit)
    if code < UTF8_TWO_BYTE_THRESHOLD { return 1 }
    if code < UTF8_THREE_BYTE_THRESHOLD { return 2 }
    return 3
}

/// Single-pass lexer over the file's UTF-16 code units. Working in UTF-16 (rather than `[Character]`)
/// keeps the `\Uxxxx` surrogate handling direct: an escape produces code units, and lone
/// surrogates are detectable per unit.
private final class StringsLexer {
    private let units: [UInt16]
    private let maxValueBytes: Int
    private var pos = 0

    init(_ text: String, maxValueBytes: Int) {
        self.units = Array(text.utf16)
        self.maxValueBytes = maxValueBytes
    }

    func parse() throws -> LocalizedStrings {
        var map: [String: String] = [:]
        while true {
            try skipWhitespaceAndComments()
            if pos >= units.count { break }
            let key = try readQuotedString(maxBytes: Int.max)
            try consumeAfterWhitespace(EQUALS)
            let value = try readQuotedString(maxBytes: maxValueBytes)
            try consumeAfterWhitespace(SEMICOLON)
            map[key] = value
        }
        return LocalizedStrings(entries: map)
    }

    private func skipWhitespaceAndComments() throws {
        while pos < units.count {
            let c = units[pos]
            let next = pos + 1 < units.count ? units[pos + 1] : nil
            if isWhitespace(c) {
                pos += 1
            } else if c == SLASH, next == SLASH {
                skipLineComment()
            } else if c == SLASH, next == STAR {
                try skipBlockComment()
            } else {
                return
            }
        }
    }

    private func skipLineComment() {
        pos += 2
        while pos < units.count, units[pos] != LF, units[pos] != CR { pos += 1 }
        if pos < units.count { pos += 1 }
    }

    private func skipBlockComment() throws {
        pos += 2
        var found = false
        while !found, pos + 1 < units.count {
            if units[pos] == STAR, units[pos + 1] == SLASH {
                pos += 2
                found = true
            } else {
                pos += 1
            }
        }
        if !found { throw StringsFailure.unterminatedComment }
    }

    private func readQuotedString(maxBytes: Int) throws -> String {
        try skipWhitespaceAndComments()
        guard pos < units.count, units[pos] == QUOTE else { throw StringsFailure.badStructure }
        pos += 1
        var out: [UInt16] = []
        var byteCount = 0
        while pos < units.count {
            let c = units[pos]
            if c == QUOTE {
                pos += 1
                return String(decoding: out, as: UTF16.self)
            } else if c == BACKSLASH {
                let escaped = try readEscape()
                for unit in escaped { byteCount = try bumpByteCount(byteCount, utf8Bytes(unit), maxBytes) }
                out.append(contentsOf: escaped)
            } else {
                pos += 1
                byteCount = try bumpByteCount(byteCount, utf8Bytes(c), maxBytes)
                out.append(c)
            }
        }
        throw StringsFailure.unterminatedString
    }

    private func bumpByteCount(_ current: Int, _ delta: Int, _ max: Int) throws -> Int {
        let next = current + delta
        if next > max { throw StringsFailure.valueTooLong }
        return next
    }

    private func consumeAfterWhitespace(_ expected: UInt16) throws {
        try skipWhitespaceAndComments()
        guard pos < units.count, units[pos] == expected else { throw StringsFailure.badStructure }
        pos += 1
    }

    /// Returns the decoded escape as code units: one for bare escapes, two for a `\Uxxxx\Uxxxx`
    /// surrogate pair. Returning a sequence lets the unicode-escape path emit a surrogate pair
    /// atomically so the caller appends and counts both halves uniformly.
    private func readEscape() throws -> [UInt16] {
        pos += 1
        guard pos < units.count else { throw StringsFailure.badEscape }
        let c = units[pos]
        switch c {
        case BACKSLASH, QUOTE:
            pos += 1
            return [c]
        case LOWER_N:
            pos += 1
            return [LF]
        case LOWER_R:
            pos += 1
            return [CR]
        case LOWER_T:
            pos += 1
            return [TAB]
        case UPPER_U:
            return try readUnicodeEscape()
        default:
            throw StringsFailure.badEscape
        }
    }

    /// Decodes one or two `\Uxxxx` escapes. Apple writes supplementary-plane codepoints as
    /// paired `\U<high>\U<low>` surrogates; the BMP path stops after one. Lone surrogates are
    /// `badEscape` - emitting them would produce malformed UTF-16 that surfaces unpredictably at
    /// any downstream UTF-8 re-encoding.
    private func readUnicodeEscape() throws -> [UInt16] {
        pos += 1
        let first = try readUnicodeCodeUnit()
        if isLowSurrogate(first) { throw StringsFailure.badEscape }
        if !isHighSurrogate(first) { return [first] }
        let partnerOk =
            pos + SURROGATE_PARTNER_PREFIX_LEN <= units.count
            && units[pos] == BACKSLASH
            && units[pos + 1] == UPPER_U
        if !partnerOk { throw StringsFailure.badEscape }
        pos += SURROGATE_PARTNER_PREFIX_LEN
        let low = try readUnicodeCodeUnit()
        if !isLowSurrogate(low) { throw StringsFailure.badEscape }
        return [first, low]
    }

    private func readUnicodeCodeUnit() throws -> UInt16 {
        guard pos + UNICODE_ESCAPE_HEX_DIGITS <= units.count else { throw StringsFailure.badEscape }
        var value = 0
        for i in 0..<UNICODE_ESCAPE_HEX_DIGITS {
            guard let scalar = Unicode.Scalar(units[pos + i]),
                let digit = Character(scalar).hexDigitValue
            else { throw StringsFailure.badEscape }
            value = (value << 4) | digit
        }
        pos += UNICODE_ESCAPE_HEX_DIGITS
        return UInt16(value)
    }
}

private func isWhitespace(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
}

private func isHighSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
private func isLowSurrogate(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

private let SLASH: UInt16 = 0x2F
private let STAR: UInt16 = 0x2A
private let QUOTE: UInt16 = 0x22
private let BACKSLASH: UInt16 = 0x5C
private let EQUALS: UInt16 = 0x3D
private let SEMICOLON: UInt16 = 0x3B
private let LF: UInt16 = 0x0A
private let CR: UInt16 = 0x0D
private let TAB: UInt16 = 0x09
private let LOWER_N: UInt16 = 0x6E
private let LOWER_R: UInt16 = 0x72
private let LOWER_T: UInt16 = 0x74
private let UPPER_U: UInt16 = 0x55

private let UNICODE_ESCAPE_HEX_DIGITS = 4
private let SURROGATE_PARTNER_PREFIX_LEN = 2
private let UTF8_TWO_BYTE_THRESHOLD = 0x80
private let UTF8_THREE_BYTE_THRESHOLD = 0x800

private let BOM_UTF8: [UInt8] = [0xEF, 0xBB, 0xBF]
private let BOM_UTF16BE: [UInt8] = [0xFE, 0xFF]
private let BOM_UTF16LE: [UInt8] = [0xFF, 0xFE]
