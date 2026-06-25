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
/// Mirror of Android's `is.walt.passes.ui.FieldLinkScanner`.
public enum FieldLinkScanner {

    private static let urlPattern = #"https?://[^\s<>"'()]+"#
    private static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    private static let phonePattern = #"(?<!\d)(\+?\d[\d\s\-()]{6,}\d)(?!\d)"#

    /// `+` and `(` immediately before a digit run signal an unmatched-paren or
    /// international form.
    private static let phonePrefixHints: Set<Character> = ["+", "("]

    /// Characters that can appear inside the matched phone substring and count
    /// as formatting hints.
    private static let internalPhoneHints: Set<Character> = ["+", "-", " "]

    private static let mirrorLabels: Set<String> = ["www", "m", "mb", "mobile"]

    public static func scan(_ fieldValue: String, source: SourceField) -> [LinkSpan] {
        // Field-level rejection: if ANY part of this field contains a Unicode
        // formatting (Cf) or control (Cc) codepoint, surface NO tappable links.
        if containsRenderingHazard(fieldValue) { return [] }

        var spans: [LinkSpan] = []

        for match in regexMatches(in: fieldValue, pattern: urlPattern) {
            spans.append(
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
            )
        }

        for match in regexMatches(in: fieldValue, pattern: emailPattern) {
            if overlapsExisting(start: match.start, end: match.endExclusive, existing: spans) {
                continue
            }
            spans.append(
                LinkSpan(
                    start: match.start,
                    endExclusive: match.endExclusive,
                    intent: .email(EmailIntent(emailAddress: match.value, sourceField: source))
                )
            )
        }

        for match in regexMatches(in: fieldValue, pattern: phonePattern) {
            let digitCount = match.value.filter(\.isNumber).count
            if digitCount < 7 { continue }
            if !hasPhoneFormattingHint(match: match, fullText: fieldValue) { continue }
            if overlapsExisting(start: match.start, end: match.endExclusive, existing: spans) {
                continue
            }
            spans.append(
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
            )
        }

        return spans.sorted(by: { $0.start < $1.start })
    }

    /// True if `s` contains any Unicode Cf (Format) or Cc (Control) codepoint.
    /// These include bidi controls (U+202A..U+202E, U+2066..U+2069, U+200E/F,
    /// U+061C), zero-width characters, and raw control bytes. All can change
    /// the rendered glyph order or visibility without changing byte content.
    public static func containsRenderingHazard(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if scalar.properties.generalCategory == .format { return true }
            if scalar.properties.generalCategory == .control { return true }
        }
        return false
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

    private static func hasPhoneFormattingHint(match: RegexMatch, fullText: String) -> Bool {
        if match.value.contains(where: { internalPhoneHints.contains($0) }) { return true }
        // Use NSString for code-unit-aligned indexing - `match.start` and
        // `match.endExclusive` are NSString offsets.
        let ns = fullText as NSString
        let before: Character? =
            match.start > 0
            ? Character(ns.substring(with: NSRange(location: match.start - 1, length: 1)))
            : nil
        let after: Character? =
            match.endExclusive < ns.length
            ? Character(ns.substring(with: NSRange(location: match.endExclusive, length: 1)))
            : nil
        if let b = before, phonePrefixHints.contains(b) { return true }
        if after == ")" { return true }
        return false
    }

    private static func overlapsExisting(
        start: Int,
        end: Int,
        existing: [LinkSpan]
    ) -> Bool {
        existing.contains { $0.start < end && start < $0.endExclusive }
    }
}

/// One detected link in a back-field value. `start` and `endExclusive` are
/// UTF-16-equivalent offsets (since the underlying regex match operates on
/// `String`'s Character indices, callers using SwiftUI's `AttributedString`
/// can map these directly).
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

internal func regexMatches(in text: String, pattern: String) -> [RegexMatch] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return []
    }
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
