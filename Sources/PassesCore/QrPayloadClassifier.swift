import Foundation

/// Classifies a QR payload string by its URI scheme so the create-time preview dialog
/// (sibling wpass-lzi.9) can warn the user about what a future scanner phone would do.
///
/// Pure logic. No network calls, no IDN normalization, no redirect following. Never
/// rejects an input — any string maps to *some* arm of `QrPayloadKind`, because the
/// structural-hazard guard (bidi controls, length caps) is upstream's job (wpass-lzi.4).
/// The classifier is deliberately conservative: when a per-scheme parse fails, the result
/// falls back to `.unknownScheme` (or `.plainText` when no scheme matched at all) rather
/// than guessing.
///
/// Scheme matching is case-insensitive per RFC 3986; the matched scheme is normalized to
/// lowercase before dispatch. All delimiter scanning walks unicode SCALARS, not Swift
/// `Character`s: a combining mark after `:`/`;`/`?` must not fuse the delimiter into a
/// non-matching grapheme cluster (Kotlin walks code units, and a hostile payload could
/// otherwise smuggle a WIFI password past the field walker). Mirror of Android's
/// `QrPayloadClassifier`.
public enum QrPayloadClassifier {

    public static func classify(_ payload: String) -> QrPayloadKind {
        // RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
        // Anchored at the start; the trailing `:` is required so a bare numeric string
        // like "1234567890" does NOT match as a scheme.
        guard let (scheme, afterScheme) = splitScheme(payload) else { return .plainText }

        switch scheme {
        case "http", "https":
            return classifyHttp(scheme: scheme, payload: payload)
        case "tel":
            return .phone(number: beforeQuery(afterScheme))
        case "sms", "smsto":
            return .sms(number: beforeQuery(afterScheme))
        case "mailto":
            return .mailto(address: beforeQuery(afterScheme))
        case "geo":
            return .geo(coords: afterScheme)
        case "wifi":
            return classifyWifi(body: afterScheme)
        case "bitcoin":
            return .bitcoin(address: beforeQuery(afterScheme))
        case "ethereum":
            return .ethereum(address: beforeQuery(afterScheme))
        case "magnet":
            return .magnet
        case "market":
            return .market(
                productId: afterScheme.hasPrefix("//") ? String(afterScheme.dropFirst(2)) : afterScheme)
        case "intent":
            return .intent(raw: payload)
        default:
            return .unknownScheme(scheme: scheme, raw: payload)
        }
    }

    /// Returns (lowercased scheme, remainder after the `:`) when the payload starts with
    /// an RFC 3986 scheme, else nil. Equivalent to Android's anchored scheme regex: the
    /// allowed character set excludes `:`, so the prefix up to the first colon is the
    /// candidate and any disallowed scalar in it (including newlines) rejects.
    private static func splitScheme(_ payload: String) -> (String, String)? {
        let scalars = payload.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":"), colon != scalars.startIndex else {
            return nil
        }
        let candidate = scalars[..<colon]
        guard let first = candidate.first, isAlpha(first) else { return nil }
        guard candidate.dropFirst().allSatisfy(isSchemeChar) else { return nil }
        return (
            String(String.UnicodeScalarView(candidate)).lowercased(),
            String(String.UnicodeScalarView(scalars[scalars.index(after: colon)...]))
        )
    }

    private static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isSchemeChar(_ scalar: Unicode.Scalar) -> Bool {
        isAlpha(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-"
            || scalar == "."
    }

    /// Mirror of Android's `substringBefore("?")`, scanning scalars.
    private static func beforeQuery(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(while: { $0 != "?" })))
    }

    private static func classifyHttp(scheme: String, payload: String) -> QrPayloadKind {
        // Malformed http(s) URI still belongs in the "URL-ish" warning bucket conceptually,
        // but with no host to surface it downgrades to unknownScheme; the preview dialog
        // shows the scheme and the raw string verbatim (Android: URISyntaxException arm).
        guard let components = URLComponents(string: payload) else {
            return .unknownScheme(scheme: scheme, raw: payload)
        }
        // `encodedHost`, not `host`: the decoded accessor IDN-converts Punycode input
        // (xn--… → Unicode). Note the parser itself IDNA-encodes Unicode hosts to
        // Punycode at parse time (Android's JDK yields host = null there instead) —
        // accepted as fail-safe: punycoding reveals homoglyph spoofs, and the verbatim
        // promise attaches to `raw`, which is preserved untouched. Empty host (e.g.
        // "http://") folds to nil per the QrPayloadKind doc.
        let host = components.encodedHost.flatMap { $0.isEmpty ? nil : $0 }
        return .url(scheme: scheme, host: host, raw: payload)
    }

    // WIFI:T:<auth>;S:<ssid>;P:<password>;H:<hidden>;;
    // SSID and password may be escaped with `\` before `;`, `,`, `:`, `\`, `"`. Field-start
    // detection walks the body with the same escape state machine `readUntilUnescapedSemicolon`
    // uses, so an escaped `\;` inside (say) a password value cannot be mistaken for a real
    // field separator and cause an `S:` substring inside the password to surface as the SSID.
    private static func classifyWifi(body: String) -> QrPayloadKind {
        let scalars = Array(body.unicodeScalars)
        guard let ssidStart = findFieldStart(body: scalars, key: "s:") else {
            return .wifi(ssid: nil)
        }
        return .wifi(ssid: readUntilUnescapedSemicolon(body: scalars, start: ssidStart))
    }

    private static func findFieldStart(body: [Unicode.Scalar], key: String) -> Int? {
        // Walk the body honoring backslash escapes so a `;` is only treated as a field
        // boundary when it wasn't itself escaped. Without this, an SSID-key substring
        // inside an escaped value (e.g. `P:my\;S:secret;S:realnet;;`) would match and
        // surface the wrong network name in the preview.
        let key = Array(key.unicodeScalars)
        var i = 0
        var prevWasUnescapedSemicolon = false
        while i < body.count {
            let atBoundary = i == 0 || prevWasUnescapedSemicolon
            let fits = i + key.count <= body.count
            if atBoundary && fits {
                let matches = (0..<key.count).allSatisfy { offset in
                    asciiLowercased(body[i + offset]) == key[offset]
                }
                if matches { return i + key.count }
            }
            if body[i] == "\\" && i + 1 < body.count {
                prevWasUnescapedSemicolon = false
                i += 2
            } else {
                prevWasUnescapedSemicolon = body[i] == ";"
                i += 1
            }
        }
        return nil
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard ("A"..."Z").contains(scalar) else { return scalar }
        return Unicode.Scalar(scalar.value + 32) ?? scalar
    }

    private static func readUntilUnescapedSemicolon(body: [Unicode.Scalar], start: Int) -> String {
        var out = String.UnicodeScalarView()
        var i = start
        while i < body.count {
            let c = body[i]
            if c == "\\" && i + 1 < body.count {
                out.append(body[i + 1])
                i += 2
                continue
            }
            if c == ";" { return String(out) }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
