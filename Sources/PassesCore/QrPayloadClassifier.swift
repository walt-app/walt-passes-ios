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
/// lowercase before dispatch. Mirror of Android's `QrPayloadClassifier`.
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
    /// candidate and any disallowed character in it (including newlines) rejects.
    private static func splitScheme(_ payload: String) -> (String, String)? {
        guard let colon = payload.firstIndex(of: ":"), colon != payload.startIndex else { return nil }
        let candidate = payload[..<colon]
        guard let first = candidate.unicodeScalars.first, isAlpha(first) else { return nil }
        guard candidate.unicodeScalars.dropFirst().allSatisfy(isSchemeChar) else { return nil }
        return (candidate.lowercased(), String(payload[payload.index(after: colon)...]))
    }

    private static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isSchemeChar(_ scalar: Unicode.Scalar) -> Bool {
        isAlpha(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-"
            || scalar == "."
    }

    /// Mirror of Android's `substringBefore("?")`.
    private static func beforeQuery(_ value: String) -> String {
        guard let mark = value.firstIndex(of: "?") else { return value }
        return String(value[..<mark])
    }

    private static func classifyHttp(scheme: String, payload: String) -> QrPayloadKind {
        // Malformed http(s) URI still belongs in the "URL-ish" warning bucket conceptually,
        // but with no host to surface it downgrades to unknownScheme; the preview dialog
        // shows the scheme and the raw string verbatim (Android: URISyntaxException arm).
        guard let components = URLComponents(string: payload) else {
            return .unknownScheme(scheme: scheme, raw: payload)
        }
        // `encodedHost`, not `host`: the decoded accessor IDN-converts Punycode
        // (xn--… → Unicode), which is exactly the normalization this classifier
        // promises not to do — the preview must show what the scanner receives.
        return .url(scheme: scheme, host: components.encodedHost, raw: payload)
    }

    // WIFI:T:<auth>;S:<ssid>;P:<password>;H:<hidden>;;
    // SSID and password may be escaped with `\` before `;`, `,`, `:`, `\`, `"`. Field-start
    // detection walks the body with the same escape state machine `readUntilUnescapedSemicolon`
    // uses, so an escaped `\;` inside (say) a password value cannot be mistaken for a real
    // field separator and cause an `S:` substring inside the password to surface as the SSID.
    private static func classifyWifi(body: String) -> QrPayloadKind {
        guard let ssidStart = findFieldStart(body: Array(body), key: "S:") else {
            return .wifi(ssid: nil)
        }
        return .wifi(ssid: readUntilUnescapedSemicolon(body: Array(body), start: ssidStart))
    }

    private static func findFieldStart(body: [Character], key: String) -> Int? {
        // Walk the body honoring backslash escapes so a `;` is only treated as a field
        // boundary when it wasn't itself escaped. Without this, an SSID-key substring
        // inside an escaped value (e.g. `P:my\;S:secret;S:realnet;;`) would match and
        // surface the wrong network name in the preview.
        let key = Array(key.lowercased())
        var i = 0
        var prevWasUnescapedSemicolon = false
        while i < body.count {
            let atBoundary = i == 0 || prevWasUnescapedSemicolon
            let fits = i + key.count <= body.count
            if atBoundary && fits {
                let region = body[i..<(i + key.count)].map { Character($0.lowercased()) }
                if region == key { return i + key.count }
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

    private static func readUntilUnescapedSemicolon(body: [Character], start: Int) -> String {
        var out = ""
        var i = start
        while i < body.count {
            let c = body[i]
            if c == "\\" && i + 1 < body.count {
                out.append(body[i + 1])
                i += 2
                continue
            }
            if c == ";" { return out }
            out.append(c)
            i += 1
        }
        return out
    }
}
