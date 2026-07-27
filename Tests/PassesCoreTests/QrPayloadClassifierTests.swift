import Foundation
import Testing

@testable import PassesCore

/// Behavior lock for `QrPayloadClassifier`, port of Android's
/// `QrPayloadClassifierTest`. Every arm of `QrPayloadKind` is covered, plus the
/// security-sensitive edge cases: bare numeric strings are plainText (not phone),
/// WIFI passwords are never carried into the kind, Punycode / mixed-script
/// hostnames pass through verbatim (no IDN conversion in core), and
/// upstream-hostile characters are not silently fixed up.
@Suite("QrPayloadClassifier")
struct QrPayloadClassifierTests {

    @Test func emptyStringIsPlainText() {
        #expect(QrPayloadClassifier.classify("") == .plainText)
    }

    @Test func bareNumericStringIsPlainTextNotPhone() {
        // Regression: a 10-digit member number must not be classified as a tel: URI just
        // because its glyphs are dial-able. The scheme rule requires a leading ALPHA and
        // a trailing `:`, so this is locked by construction; the test pins the property.
        #expect(QrPayloadClassifier.classify("1234567890") == .plainText)
    }

    @Test func arbitraryTextWithoutSchemeIsPlainText() {
        #expect(QrPayloadClassifier.classify("hello world") == .plainText)
    }

    @Test func newlineSeparatedTextIsPlainText() {
        // Documented behavior: the classifier does NOT split multi-line payloads; the
        // newline disqualifies the pre-colon prefix as a scheme.
        #expect(QrPayloadClassifier.classify("line1\nline2") == .plainText)
    }

    @Test func httpsUrlExposesSchemeHostAndRaw() {
        let raw = "https://walt.is/example"
        #expect(
            QrPayloadClassifier.classify(raw) == .url(scheme: "https", host: "walt.is", raw: raw))
    }

    @Test func httpUrlExposesSchemeHostAndRaw() {
        let raw = "http://example.com/path?q=1"
        #expect(
            QrPayloadClassifier.classify(raw) == .url(scheme: "http", host: "example.com", raw: raw))
    }

    @Test func httpsUrlWithUserInfoUsesAuthorityHost() {
        let raw = "https://user:pass@host.example/"
        guard case .url(_, let host, let rawOut) = QrPayloadClassifier.classify(raw) else {
            Issue.record("expected url kind")
            return
        }
        #expect(host == "host.example")
        #expect(rawOut == raw)
    }

    @Test func httpsUrlWithMixedScriptHostnameClassifiesWithoutCrash() {
        // Mixed-script hostname (Cyrillic er + Greek gamma in a Latin-looking name). The
        // classifier must NOT homoglyph-detect or normalize; downstream UI renders `raw`
        // verbatim. Host is platform-parser-defined (Android's JDK yields null here; iOS
        // URLComponents may yield the literal) and is deliberately unasserted.
        let raw = "https://паγpal.com/"
        guard case .url(let scheme, _, let rawOut) = QrPayloadClassifier.classify(raw) else {
            Issue.record("expected url kind")
            return
        }
        #expect(scheme == "https")
        #expect(rawOut == raw)
    }

    @Test func punycodeHostnameIsLeftVerbatim() {
        let raw = "https://xn--80ak6aa92e.com/"
        guard case .url(_, let host, let rawOut) = QrPayloadClassifier.classify(raw) else {
            Issue.record("expected url kind")
            return
        }
        #expect(host == "xn--80ak6aa92e.com")
        #expect(rawOut == raw)
    }

    @Test func trailingWhitespaceIsNotSilentlyFixed() {
        // Upstream validator rejects whitespace; if it slipped through, the raw payload
        // must survive verbatim into the preview. URI parsing may or may not accept the
        // trailing whitespace; either way raw is preserved (mirror of the Android test).
        let raw = "https://attacker.example/  "
        switch QrPayloadClassifier.classify(raw) {
        case .url(_, _, let rawOut): #expect(rawOut == raw)
        case .unknownScheme(_, let rawOut): #expect(rawOut == raw)
        default: Issue.record("expected url or unknownScheme")
        }
    }

    @Test func telUriIsPhone() {
        #expect(QrPayloadClassifier.classify("tel:+15551234567") == .phone(number: "+15551234567"))
    }

    @Test func telUriStripsQueryTail() {
        // Mirrors the sms/mailto/bitcoin behavior so the preview renders a clean dialable
        // number; consistency with the other phone-like arms wins over RFC 3966 purity.
        #expect(
            QrPayloadClassifier.classify("tel:+15551234567?foo=bar")
                == .phone(number: "+15551234567"))
    }

    @Test func smsUriStripsQueryTail() {
        #expect(
            QrPayloadClassifier.classify("sms:+15551234567?body=hi") == .sms(number: "+15551234567"))
    }

    @Test func mailtoUriStripsQueryTail() {
        #expect(
            QrPayloadClassifier.classify("mailto:a@b.com?subject=hello")
                == .mailto(address: "a@b.com"))
    }

    @Test func geoUriExposesCoords() {
        #expect(
            QrPayloadClassifier.classify("geo:37.7749,-122.4194")
                == .geo(coords: "37.7749,-122.4194"))
    }

    @Test func wifiUriExposesSsidButNeverPassword() {
        let kind = QrPayloadClassifier.classify("WIFI:T:WPA;S:my-network;P:hunter2;;")
        #expect(kind == .wifi(ssid: "my-network"))
        // Belt-and-suspenders: no field on the result carries the password substring.
        #expect(!String(describing: kind).contains("hunter2"))
    }

    @Test func wifiUriWithoutSsidReturnsNilSsid() {
        #expect(QrPayloadClassifier.classify("WIFI:T:nopass;;") == .wifi(ssid: nil))
    }

    @Test func wifiUriWithEscapedSemicolonInSsidUnescapes() {
        // SSID is `weird;name`: escaped `\;` yields a literal `;`, not a field end.
        let kind = QrPayloadClassifier.classify(#"WIFI:S:weird\;name;T:WPA;P:secret;;"#)
        #expect(kind == .wifi(ssid: "weird;name"))
        #expect(!String(describing: kind).contains("secret"))
    }

    @Test func wifiUriWithFakeSsidKeyInsideEscapedPasswordDoesNotSpoof() {
        // Field-boundary detection must honor escapes: the `\;` inside the password value
        // is NOT a real separator, so the `S:` substring after it is NOT a real SSID key.
        let kind = QrPayloadClassifier.classify(#"WIFI:T:WPA;P:my\;S:secret;S:realnet;;"#)
        #expect(kind == .wifi(ssid: "realnet"))
        #expect(!String(describing: kind).contains("my"))
    }

    @Test func bitcoinUriStripsAmountTail() {
        #expect(
            QrPayloadClassifier.classify("bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?amount=0.5")
                == .bitcoin(address: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
    }

    @Test func ethereumUriStripsValueTail() {
        #expect(
            QrPayloadClassifier.classify("ethereum:0xabc?value=1") == .ethereum(address: "0xabc"))
    }

    @Test func magnetUriClassifies() {
        #expect(QrPayloadClassifier.classify("magnet:?xt=urn:btih:abc") == .magnet)
    }

    @Test func marketUriWithAuthoritySliceExposesProductId() {
        #expect(
            QrPayloadClassifier.classify("market://details?id=com.example.app")
                == .market(productId: "details?id=com.example.app"))
    }

    @Test func marketUriWithoutAuthoritySliceExposesProductId() {
        #expect(
            QrPayloadClassifier.classify("market:details?id=com.example.app")
                == .market(productId: "details?id=com.example.app"))
    }

    @Test func intentUriKeepsRawString() {
        let raw = "intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end"
        #expect(QrPayloadClassifier.classify(raw) == .intent(raw: raw))
    }

    @Test func uppercaseSchemeIsNormalizedBeforeDispatch() {
        // Schemes are case-insensitive per RFC 3986; the address carries verbatim from
        // after the scheme.
        #expect(
            QrPayloadClassifier.classify("BITCOIN:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
                == .bitcoin(address: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
    }

    @Test func unrecognizedSchemeReturnsUnknownScheme() {
        #expect(
            QrPayloadClassifier.classify("foo://bar")
                == .unknownScheme(scheme: "foo", raw: "foo://bar"))
    }

    @Test func unknownSchemeNormalizesToLowercase() {
        #expect(
            QrPayloadClassifier.classify("FOO://bar")
                == .unknownScheme(scheme: "foo", raw: "FOO://bar"))
    }
}
