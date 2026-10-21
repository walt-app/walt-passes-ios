import Foundation
import Testing

@testable import PassesUI

/// Mirror of Android's `FieldLinkScannerTest`. Verbatim case names; assertions
/// translate `assertThat(...).isInstanceOf(B3UrlIntent::class.java)` to
/// `if case .url = span.intent` and `assertThat(...).hasSize(N)` to
/// `#expect(spans.count == N)`.
@Suite("FieldLinkScanner")
struct FieldLinkScannerTests {

    private let source = linkScannerTestSource

    @Test func detectsHttpsUrl() {
        let spans = FieldLinkScanner.scan(
            "Visit https://acme.example/help for assistance.",
            source: source
        )
        #expect(spans.count == 1)
        guard case .url(let intent) = spans[0].intent else {
            Issue.record("expected url")
            return
        }
        #expect(intent.url == "https://acme.example/help")
    }

    @Test func detectsHttpUrl() {
        let spans = FieldLinkScanner.scan("http://example.com/x", source: source)
        if case .url = spans.first?.intent {
        } else {
            Issue.record("expected url")
        }
    }

    @Test func doesNotDetectSchemeLessUrl() {
        #expect(FieldLinkScanner.scan("acme.example", source: source).isEmpty)
    }

    @Test func detectsEmail() {
        let spans = FieldLinkScanner.scan(
            "Email support@acme.example for help",
            source: source
        )
        guard case .email(let i) = spans.first?.intent else {
            Issue.record("expected email")
            return
        }
        #expect(i.emailAddress == "support@acme.example")
    }

    @Test func emailsBesidePunctuationAndInProseKeepExactRanges() {
        let texts = [
            "(support@acme.example)",
            "<support@acme.example>",
            "\"support@acme.example\"",
            "Mail: support@acme.example.",
            "Mail support@acme.example, or call.",
            "Write to support@acme.example!",
            "Mail support@acme.example\nThanks",
        ]
        for text in texts {
            expectExactSpans(text, [("support@acme.example", .email)])
        }
    }

    @Test func emailLocalPartTakesTheWholeRun() {
        let emails = [
            "first.last+tag@mail.acme.example",
            "a_b%c-d@acme-1.example",
            "Ops.Team@Acme.EXAMPLE",
            "x@acme.example",
        ]
        for email in emails {
            expectExactSpans("Contact \(email) today", [(email, .email)])
        }
    }

    @Test func emailDomainEndsAtTheLastValidTld() {
        expectExactSpans("a@b.example..", [("a@b.example", .email)])
        expectExactSpans("a@b.example.c", [("a@b.example", .email)])
        expectExactSpans("a@b.example-1", [("a@b.example", .email)])
        expectExactSpans("a@b.c.de.f1", [("a@b.c.de", .email)])
    }

    @Test func emailWithoutUsableDomainDoesNotLink() {
        for text in ["a@", "@acme.example", "a@acme", "a@acme.e", "a@@acme.example", "a@."] {
            #expect(FieldLinkScanner.scan(text, source: source).isEmpty, "\(text)")
        }
    }

    @Test func separatedEmailsAllLink() {
        expectExactSpans(
            "a@b.example, c@d.example;e@f.example g@h.example",
            [
                ("a@b.example", .email),
                ("c@d.example", .email),
                ("e@f.example", .email),
                ("g@h.example", .email),
            ]
        )
    }

    @Test func emailNeverStartsInsideAPreviousAddress() {
        // A match may not start mid-run or right after an `@`, so only the first address links.
        let cases = [
            ("a@b.example-c@d.example", "a@b.example"),
            ("a@b.example.c@d.example", "a@b.example"),
            ("a@b.ex1@d.example", "a@b.ex"),
            ("a@b.co1x@y.co2z@w.co", "a@b.co"),
            ("a@b.example-c@d.example@e.example", "a@b.example"),
        ]
        for (text, first) in cases {
            expectExactSpans(text, [(first, .email)])
        }
        #expect(FieldLinkScanner.scan("a@b@c.example", source: source).isEmpty)
    }

    @Test func detectsInternationalPhone() {
        let spans = FieldLinkScanner.scan(
            "Call us at +1 (555) 123-4567 anytime.",
            source: source
        )
        guard case .phone(let i) = spans.first?.intent else {
            Issue.record("expected phone")
            return
        }
        #expect(i.phoneNumber == "+1 (555) 123-4567")
    }

    @Test func rejectsShortDigitRunsAsPhone() {
        #expect(FieldLinkScanner.scan("Promo code 12345", source: source).isEmpty)
    }

    @Test func rejectsBareEightDigitTicketNumberAsPhone() {
        #expect(FieldLinkScanner.scan("10203040", source: source).isEmpty)
    }

    @Test func rejectsBareSevenDigitOrderNumberAsPhone() {
        #expect(FieldLinkScanner.scan("1020304", source: source).isEmpty)
    }

    @Test func rejectsLongBareDigitRunAsPhone() {
        #expect(FieldLinkScanner.scan("123456789012", source: source).isEmpty)
    }

    @Test func rejectsBareDigitRunAdjacentToProseAsPhone() {
        #expect(FieldLinkScanner.scan("Order 10203040 placed.", source: source).isEmpty)
    }

    @Test func acceptsPhoneWithOnlySpaceHint() {
        let spans = FieldLinkScanner.scan("Call 555 123 4567 today.", source: source)
        #expect(spans.count == 1)
        guard case .phone(let i) = spans.first?.intent else {
            Issue.record("expected phone")
            return
        }
        #expect(i.phoneNumber == "555 123 4567")
    }

    @Test func acceptsPhoneWithOnlyDashHint() {
        let spans = FieldLinkScanner.scan("555-123-4567", source: source)
        #expect(spans.count == 1)
        if case .phone = spans.first?.intent {} else { Issue.record("expected phone") }
    }

    @Test func acceptsPhoneWithOnlyParenHint() {
        let spans = FieldLinkScanner.scan("Call (5551234567) now.", source: source)
        #expect(spans.count == 1)
        if case .phone = spans.first?.intent {} else { Issue.record("expected phone") }
    }

    @Test func acceptsPhoneWithOnlyPlusHint() {
        let spans = FieldLinkScanner.scan("+15551234567", source: source)
        #expect(spans.count == 1)
        guard case .phone(let i) = spans.first?.intent else {
            Issue.record("expected phone")
            return
        }
        #expect(i.phoneNumber == "+15551234567")
    }

    @Test func emailInsideUrlIsNotDoubleClaimed() {
        let spans = FieldLinkScanner.scan("https://x@example.com/path", source: source)
        #expect(spans.count == 1)
        if case .url = spans.first?.intent {} else { Issue.record("expected url") }
    }

    @Test func multipleLinksReturnInOrder() {
        let text = "Site https://a.example or call +1-555-123-4567 or mailto:b@c.example."
        let spans = FieldLinkScanner.scan(text, source: source)
        let kinds: [String] = spans.map {
            switch $0.intent {
            case .url: return "url"
            case .phone: return "phone"
            case .email: return "email"
            }
        }
        #expect(kinds == ["url", "phone", "email"])
    }

    @Test func targetStringIsVerbatim() {
        let text = "Reach me at  +44  20  7946  0958 ."
        let spans = FieldLinkScanner.scan(text, source: source)
        guard case .phone(let i) = spans.first?.intent else {
            Issue.record("expected phone")
            return
        }
        #expect(i.phoneNumber == "+44  20  7946  0958")
    }

    @Test func sourceFieldIsCarriedThrough() {
        let spans = FieldLinkScanner.scan("https://example.com", source: source)
        #expect(spans.first?.intent.sourceField == source)
    }

    @Test func urlContainingRightToLeftOverrideIsRejected() {
        let attack = "https://attacker.example/\u{202E}gpj.elgoog//:sptth"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func urlContainingZeroWidthSpaceIsRejected() {
        let attack = "https://goog\u{200B}le.com/path"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func urlContainingLeftToRightMarkIsRejected() {
        let attack = "https://example.com/\u{200E}path"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func urlContainingArabicLetterMarkIsRejected() {
        let attack = "https://example.com/\u{061C}path"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func urlContainingControlCharIsRejected() {
        let attack = "https://example.com/\u{0007}beep"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func emailContainingBidiCharIsRejected() {
        let attack = "support\u{202E}@example.com"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func phoneContainingBidiCharIsRejected() {
        let attack = "+1 555\u{202E} 123 4567"
        #expect(FieldLinkScanner.scan(attack, source: source).isEmpty)
    }

    @Test func cleanAdjacentToBidiHostileSurfacesNothingFromTheField() {
        let mixed = "Visit https://example.com or https://attacker.example/\u{202E}gpj.elgoog//:sptth"
        #expect(FieldLinkScanner.scan(mixed, source: source).isEmpty)
    }

    @Test func urlBytesAreVerbatimNoCfStripping() {
        let clean = "https://example.com/path?q=1"
        let spans = FieldLinkScanner.scan(clean, source: source)
        guard case .url(let i) = spans.first?.intent else {
            Issue.record("expected url")
            return
        }
        #expect(i.url == clean)
    }

    @Test func percentEncodedBidiInUrlIsAccepted() {
        let url = "https://example.com/%E2%80%AEsomething"
        let spans = FieldLinkScanner.scan(url, source: source)
        #expect(spans.count == 1)
        guard case .url(let i) = spans.first?.intent else {
            Issue.record("expected url")
            return
        }
        #expect(i.url == url)
    }

    @Test func containsRenderingHazardCoversFormatAndControlCategories() {
        let hazards: [String] = [
            "\u{202E}",  // RLO
            "\u{202D}",  // LRO
            "\u{2066}",  // LRI
            "\u{2067}",  // RLI
            "\u{2068}",  // FSI
            "\u{2069}",  // PDI
            "\u{200B}",  // ZWSP
            "\u{200E}",  // LRM
            "\u{200F}",  // RLM
            "\u{061C}",  // ALM
            "\u{FEFF}",  // ZWNBSP / BOM
            "\u{0000}",  // NUL
            "\u{0007}",  // BEL
            "\u{001B}",  // ESC
        ]
        for hazard in hazards {
            #expect(
                FieldLinkScanner.containsRenderingHazard("safe\(hazard)"),
                "U+\(String(hazard.unicodeScalars.first!.value, radix: 16, uppercase: true)) should flag as hazard"
            )
        }
    }

    @Test func containsRenderingHazardAcceptsPlainAscii() {
        #expect(!FieldLinkScanner.containsRenderingHazard("https://example.com/path"))
    }

    @Test func phoneScanCompletesQuicklyOnPathologicalInput() {
        expectLinearScan(String(repeating: "0123456789", count: 410))  // ~4096
    }

    @Test func mixedAlphaDigitSoupCompletesQuickly() {
        expectLinearScan(String(repeating: "5 -", count: 2048))
    }

    @Test func phoneDenseFieldScansInLinearTime() {
        // Every `+` is a hint and starts a new 8-digit match inside one long run.
        expectLinearScan(String(repeating: "+12345678 ", count: 15_000))
    }

    @Test func mixedDigitRunScansInLinearTime() {
        // One run spanning the field, mixed by U+0663, holding 15k rejected phone matches.
        expectLinearScan(String(repeating: "1234-5678 \u{0663} ", count: 15_000))
    }

    @Test func emailLocalPartRunWithoutAtScansInLinearTime() {
        expectLinearScan(String(repeating: "a", count: 200_000))
    }

    @Test func emailDomainWithoutTldScansInLinearTime() {
        // The domain never ends in a TLD, and is itself one long local-part run.
        expectLinearScan("a@" + String(repeating: "a.", count: 100_000))
    }

    @Test func phoneShapedLocalPartRunScansInLinearTime() {
        // One unbroken local-part run without `@`, holding 22k phone matches.
        expectLinearScan(String(repeating: "+12345678", count: 22_000))
    }

    // -- registrableDomain extraction ------------------------------------------

    @Test func registrableDomainKeepsTwoLabelMirrorHost() {
        let spans = FieldLinkScanner.scan("https://m.com/x", source: source)
        guard case .url(let i) = spans.first?.intent else {
            Issue.record("expected url")
            return
        }
        #expect(i.registrableDomain == "m.com")
    }

    @Test func registrableDomainKeepsTwoLabelMobileHost() {
        let spans = FieldLinkScanner.scan("https://mobile.io/", source: source)
        guard case .url(let i) = spans.first?.intent else {
            Issue.record("expected url")
            return
        }
        #expect(i.registrableDomain == "mobile.io")
    }

    @Test func registrableDomainStripsLeadingWww() {
        #expect(FieldLinkScanner.registrableDomainOf("https://www.example.com/a") == "example.com")
    }

    @Test func registrableDomainReturnsNilForNonHttpScheme() {
        #expect(FieldLinkScanner.registrableDomainOf("mailto:x@y.example") == nil)
    }
}
