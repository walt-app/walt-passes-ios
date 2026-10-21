import Foundation

/// Detects URLs, phone numbers, and email addresses in pass back-field values.
/// Returns `LinkSpan` entries with their indexes into the original string so
/// the UI layer can render them as tappable affordances pointing at the
/// corresponding `SecurityIntent`.
///
/// Trust-claim relevance: the scanner extracts the exact substring that
/// becomes the intent's target. There is no normalization or scheme injection;
/// the string the user sees in the confirmation sheet is the same string this
/// scanner pulled out of the pass.
///
/// Intentionally conservative: prefers false negatives over false positives.
///
/// - A URL needs an `http`/`https` scheme and runs to the first Unicode
///   White_Space character or one of `<>"'()`.
/// - A phone number needs at least seven ASCII digits and a formatting hint (a
///   leading `+`, an ASCII space, dash, or parenthesis). Digit groups may be
///   separated by U+0020, U+00A0, U+2007, U+2009 or U+202F, so a match never
///   crosses a tab or line break. A run (decimal digits plus those separators and
///   `+-()`) holding any non-ASCII decimal digit yields no link rather than a
///   truncated one, so the dialled digits are exactly the ones displayed.
/// - An email starts only where a run of local-part characters starts and never
///   right after an `@`, so in `a@b.example-c@d.example` only `a@b.example` links
///   and a long run without a usable `@` is read once, not once per position.
///
/// Rendering hazards are checked twice: `containsFieldHazard` gates the whole
/// field (only LF, tab and CRLF pass), then `containsRenderingHazard` rejects any
/// match holding a Cf, Cc, Zl or Zp scalar, so no actionable string carries one.
///
/// The patterns spell out their character classes rather than `\s` / `\d`, which
/// are Unicode-aware on ICU.
///
/// Mirror of Android's `is.walt.passes.ui.FieldLinkScanner`.
public enum FieldLinkScanner {

    // Stops at any Unicode White_Space character or `<>"'()`.
    private static let urlRegex = compile(
        #"https?://[^\t\n\u000B\f\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000<>"'()]+"#)

    // A match starts only where a local-part run starts and not after an `@`; `@` is
    // outside the possessive `++` class.
    private static let emailRegex = compile(
        #"(?<![A-Za-z0-9._%+\-@])[A-Za-z0-9._%+\-]++@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    // Separators must match `phoneRunPunctuation`.
    private static let phoneRegex = compile(
        #"(?<!\p{Nd})(\+?[0-9][0-9 \u00A0\u2007\u2009\u202F\-()]{6,}[0-9])(?!\p{Nd})"#)

    /// `+` and `(` immediately before a digit run signal an unmatched-paren or
    /// international form.
    private static let phonePrefixHints: Set<UInt16> = [UInt16(UInt8(ascii: "+")), UInt16(UInt8(ascii: "("))]

    /// Characters that can appear inside the matched phone substring and count
    /// as formatting hints. No-break spaces are not hints: such a number without
    /// `+` stays unlinked.
    private static let internalPhoneHints: Set<Character> = ["+", "-", " "]

    /// Non-digit scalars that extend a phone run for the mixed-digit check; the same
    /// separators as `phoneRegex`.
    private static let phoneRunPunctuation: Set<Unicode.Scalar> = [
        " ", "\u{00A0}", "\u{2007}", "\u{2009}", "\u{202F}", "-", "(", ")", "+",
    ]

    private static let mirrorLabels: Set<String> = ["www", "m", "mb", "mobile"]

    public static func scan(_ fieldValue: String, source: SourceField) -> [LinkSpan] {
        if containsFieldHazard(fieldValue) { return [] }

        let urls = cleanMatches(in: fieldValue, urlRegex).map { match in
            LinkSpan(
                start: match.start,
                endExclusive: match.endExclusive,
                intent: .url(
                    B3UrlIntent(
                        url: match.value,
                        sourceField: source,
                        registrableDomain: registrableDomainOf(match.value)
                    )
                )
            )
        }

        // Skip emails inside an already-claimed URL span ("http://x@y.com").
        var urlClaims = ClaimedRanges(urls)
        let emails = cleanMatches(in: fieldValue, emailRegex)
            .filter { !urlClaims.overlaps(start: $0.start, endExclusive: $0.endExclusive) }
            .map { match in
                LinkSpan(
                    start: match.start,
                    endExclusive: match.endExclusive,
                    intent: .email(EmailIntent(emailAddress: match.value, sourceField: source))
                )
            }

        var claims = ClaimedRanges((urls + emails).sorted { $0.start < $1.start })
        let phoneMatches = cleanMatches(in: fieldValue, phoneRegex)
            .filter { isLinkablePhone(match: $0, fullText: fieldValue) }
        let mixedRuns = phoneMatches.isEmpty ? nil : mixedDigitRuns(fieldValue)
        let phones =
            phoneMatches
            .filter { mixedRuns?[$0.start] != true }
            .filter { !claims.overlaps(start: $0.start, endExclusive: $0.endExclusive) }
            .map { match in
                LinkSpan(
                    start: match.start,
                    endExclusive: match.endExclusive,
                    intent: .phone(
                        PhoneIntent(
                            phoneNumber: match.value.trimmingCharacters(in: .whitespaces),
                            sourceField: source
                        )
                    )
                )
            }

        return (urls + emails + phones).sorted { $0.start < $1.start }
    }

    /// True if `s` contains any Unicode Cf (Format) or Cc (Control) scalar, or a
    /// line or paragraph separator (U+2028 / U+2029). These include bidi controls
    /// (U+202A..U+202E, U+2066..U+2069, U+200E/F, U+061C), zero-width characters,
    /// supplementary-plane TAG characters, and raw control bytes. All can change
    /// the rendered glyph order, visibility or line layout without changing what
    /// the string resolves to. Applied to every matched link substring.
    public static func containsRenderingHazard(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: isHazard)
    }

    /// Whole-field gate: `containsRenderingHazard` minus line feed, tab, and
    /// carriage return directly followed by line feed. A lone carriage return is a
    /// hazard. Iterates scalars because Swift treats CRLF as one `Character`.
    static func containsFieldHazard(_ s: String) -> Bool {
        var pendingCarriageReturn = false
        for scalar in s.unicodeScalars {
            if pendingCarriageReturn && scalar != "\n" { return true }
            pendingCarriageReturn = scalar == "\r"
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { continue }
            if isHazard(scalar) { return true }
        }
        return pendingCarriageReturn
    }

    private static func isHazard(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Best-effort PSL-free registrable-domain extraction. Strips scheme,
    /// authority slice, userinfo, port, and a leading `www`/`m`/`mb`/`mobile`
    /// label (only when 3+ labels remain so `m.com` stays `m.com`).
    public static func registrableDomainOf(_ url: String) -> String? {
        var stripped = url
        if stripped.hasPrefix("https://") {
            stripped.removeFirst("https://".count)
        } else if stripped.hasPrefix("http://") {
            stripped.removeFirst("http://".count)
        } else {
            return nil
        }
        let authorityEnd = stripped.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        let authority = authorityEnd.map { String(stripped[..<$0]) } ?? stripped
        if authority.isEmpty { return nil }
        let afterUserinfo: String = {
            if let at = authority.lastIndex(of: "@") {
                return String(authority[authority.index(after: at)...])
            }
            return authority
        }()
        let hostAndPort: String = {
            if afterUserinfo.hasPrefix("[") {
                if let close = afterUserinfo.firstIndex(of: "]") {
                    return String(afterUserinfo[...close])
                }
                return ""
            }
            if let colon = afterUserinfo.firstIndex(of: ":") {
                return String(afterUserinfo[..<colon])
            }
            return afterUserinfo
        }()
        if hostAndPort.isEmpty { return nil }
        var host = hostAndPort.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.count < 3 { return host }
        if let first = labels.first, mirrorLabels.contains(first) {
            return labels.dropFirst().joined(separator: ".")
        }
        return host
    }

    private static func cleanMatches(in text: String, _ regex: NSRegularExpression) -> [RegexMatch] {
        regexMatches(in: text, regex: regex).filter { !containsRenderingHazard($0.value) }
    }

    // The patterns are constants, so a failure here is a programming error caught by every test run.
    private static func compile(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func isLinkablePhone(match: RegexMatch, fullText: String) -> Bool {
        match.value.utf8.count(where: { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) >= 7
            && hasPhoneFormattingHint(match: match, fullText: fullText)
    }

    // Hint: an internal `+`, dash or ASCII space, or an adjacent `+` / `(` before or
    // `)` after. Offsets are UTF-16, so neighbours are read as code units.
    private static func hasPhoneFormattingHint(match: RegexMatch, fullText: String) -> Bool {
        if match.value.contains(where: { internalPhoneHints.contains($0) }) { return true }
        let ns = fullText as NSString
        if match.start > 0, phonePrefixHints.contains(ns.character(at: match.start - 1)) { return true }
        return match.endExclusive < ns.length && ns.character(at: match.endExclusive) == UInt16(UInt8(ascii: ")"))
    }

    /// Flags, in one linear pass, every UTF-16 offset inside a run holding a
    /// non-ASCII decimal digit; nil when no run does. A phone match starting in
    /// such a run is a truncated slice, so it is dropped.
    private static func mixedDigitRuns(_ text: String) -> [Bool]? {
        var flags: [Bool]?
        var runStart = 0
        var offset = 0
        var mixed = false
        func closeRun(at end: Int) {
            if mixed {
                if flags == nil { flags = Array(repeating: false, count: text.utf16.count) }
                for i in runStart..<end { flags?[i] = true }
            }
            mixed = false
        }
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            let isDigit = scalar.properties.generalCategory == .decimalNumber
            if isDigit || phoneRunPunctuation.contains(scalar) {
                if isDigit && !scalar.isASCII { mixed = true }
            } else {
                closeRun(at: offset)
                runStart = offset + width
            }
            offset += width
        }
        closeRun(at: offset)
        return flags
    }
}

/// Overlap queries for ascending, disjoint ranges against sorted, disjoint
/// claimed spans; linear overall.
private struct ClaimedRanges {
    private let claimed: [LinkSpan]
    private var next = 0

    init(_ claimed: [LinkSpan]) { self.claimed = claimed }

    mutating func overlaps(start: Int, endExclusive: Int) -> Bool {
        while next < claimed.count && claimed[next].endExclusive <= start { next += 1 }
        return next < claimed.count && claimed[next].start < endExclusive
    }
}

/// One detected link in a back-field value. `start` and `endExclusive` are UTF-16
/// code-unit offsets (`NSString` / `NSRange` units), not `Character` counts: a CRLF
/// is one `Character` but two offsets.
///
/// The memberwise initializer is internal (Swift's default for a `public` struct), so
/// consumers can only obtain a `LinkSpan` from `FieldLinkScanner.scan`, which guarantees
/// the target survived validation.
public struct LinkSpan: Sendable, Equatable {
    public let start: Int
    public let endExclusive: Int
    public let intent: SecurityIntent
}

// MARK: - Regex helpers

internal struct RegexMatch {
    let value: String
    /// Inclusive UTF-16-code-unit offset into the original `String`.
    let start: Int
    /// Exclusive UTF-16-code-unit offset.
    let endExclusive: Int
}

internal func regexMatches(in text: String, regex: NSRegularExpression) -> [RegexMatch] {
    let nsText = text as NSString
    let full = NSRange(location: 0, length: nsText.length)
    let matches = regex.matches(in: text, options: [], range: full)
    return matches.compactMap { result in
        let range = result.range
        guard range.location != NSNotFound else { return nil }
        let value = nsText.substring(with: range)
        return RegexMatch(
            value: value,
            start: range.location,
            endExclusive: range.location + range.length
        )
    }
}
