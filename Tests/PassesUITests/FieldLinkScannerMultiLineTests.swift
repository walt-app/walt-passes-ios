import Foundation
import Testing

@testable import PassesUI

/// Multi-line fields and engine-independent character classes. Mirror of the matching
/// cases in Android's `FieldLinkScannerTest`.
@Suite("FieldLinkScanner multi-line")
struct FieldLinkScannerMultiLineTests {

    // -- Multi-line fields -----------------------------------------------------
    //
    // Line breaks and tabs separate lines and columns in real back fields. They must
    // not suppress links, but no link target may contain one.

    @Test func multiLineFieldYieldsEveryLinkWithExactRanges() {
        let text =
            "Terms apply.\nHelp: https://acme.example/help\nMail support@acme.example\n"
            + "Phone +1 555 123 4567\nThanks"
        expectExactSpans(
            text,
            [
                ("https://acme.example/help", .url),
                ("support@acme.example", .email),
                ("+1 555 123 4567", .phone),
            ]
        )
    }

    @Test func crlfFieldYieldsEveryLinkWithExactRanges() {
        let text =
            "Terms apply.\r\nhttps://acme.example/help\r\nsupport@acme.example\r\n"
            + "+1 555 123 4567\r\n"
        expectExactSpans(
            text,
            [
                ("https://acme.example/help", .url),
                ("support@acme.example", .email),
                ("+1 555 123 4567", .phone),
            ]
        )
    }

    @Test func tabSeparatedFieldYieldsEveryLinkWithExactRanges() {
        let text = "Web:\thttps://acme.example/help\tMail:\tsupport@acme.example\tTel:\t+1 555 123 4567"
        expectExactSpans(
            text,
            [
                ("https://acme.example/help", .url),
                ("support@acme.example", .email),
                ("+1 555 123 4567", .phone),
            ]
        )
    }

    @Test func urlStopsAtLineBreak() {
        expectExactSpans("https://acme.example/a\nnext line", [("https://acme.example/a", .url)])
    }

    @Test func phoneStopsAtLineBreak() {
        expectExactSpans("Tel +1 555 123 4567\n10203040", [("+1 555 123 4567", .phone)])
    }

    @Test func phoneAfterLineEndingInDigitIsFound() {
        expectExactSpans("Order 77\r\n555-123-4567", [("555-123-4567", .phone)])
    }

    @Test func phoneAfterTabFollowingDigitIsFound() {
        expectExactSpans("Seat 4\t555-123-4567", [("555-123-4567", .phone)])
    }

    @Test func urlEndsBeforeUnicodeWhitespace() {
        // The URL class excludes the White_Space set. The other six members (VT, FF,
        // lone CR, NEL, U+2028, U+2029) are field hazards.
        var spaces: [Unicode.Scalar] = ["\t", "\n", " ", "\u{00A0}", "\u{1680}"]
        spaces += (0x2000...0x200A).compactMap(Unicode.Scalar.init)
        spaces += ["\u{202F}", "\u{205F}", "\u{3000}"]
        for space in spaces {
            expectExactSpans("https://acme.example/a\(Character(space))b", [("https://acme.example/a", .url)])
        }
    }

    @Test func whiteSpaceFieldHazardsYieldNoLinks() {
        for space in ["\u{000B}", "\u{000C}", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            #expect(
                FieldLinkScanner.scan("Help\(space)https://acme.example/help", source: linkScannerTestSource).isEmpty,
                "\(codepoint(space)) must reject the field"
            )
        }
    }

    @Test func loneCarriageReturnRejectsTheField() {
        // A lone CR may render with no width, hiding where a link ends.
        #expect(FieldLinkScanner.scan("support@bank.example\rm", source: linkScannerTestSource).isEmpty)
        #expect(FieldLinkScanner.scan("Line\rhttps://acme.example/help", source: linkScannerTestSource).isEmpty)
    }

    @Test func urlContainingSupplementaryTagCharIsRejected() {
        // U+E0001 LANGUAGE TAG, a Cf codepoint encoded as a surrogate pair.
        #expect(FieldLinkScanner.scan("https://acme.example/\u{E0001}path", source: linkScannerTestSource).isEmpty)
    }

    @Test func supplementaryFormatCharElsewhereRejectsTheWholeField() {
        // U+E0020 TAG SPACE on its own line, away from the link.
        #expect(
            FieldLinkScanner.scan("Note \u{E0020}\nhttps://acme.example/help", source: linkScannerTestSource).isEmpty)
    }

    @Test func supplementaryFormatCharsAreHazardsAtBothLevels() {
        // LANGUAGE TAG, TAG SPACE, SHORTHAND FORMAT LETTER OVERLAP, MUSICAL SYMBOL BEGIN BEAM.
        for hazard in ["\u{E0001}", "\u{E0020}", "\u{1BCA0}", "\u{1D173}"] {
            #expect(FieldLinkScanner.containsFieldHazard("safe\(hazard)"), "\(codepoint(hazard)) field")
            #expect(FieldLinkScanner.containsRenderingHazard("safe\(hazard)"), "\(codepoint(hazard)) match")
        }
    }

    @Test func multiLineUrlContainingBidiOverrideIsRejected() {
        let text = "Line one\nhttps://attacker.example/\u{202E}gpj.elgoog//:sptth\nLine three"
        #expect(FieldLinkScanner.scan(text, source: linkScannerTestSource).isEmpty)
    }

    @Test func multiLineUrlContainingZeroWidthSpaceIsRejected() {
        #expect(
            FieldLinkScanner.scan("Help:\nhttps://goog\u{200B}le.com/path\n", source: linkScannerTestSource).isEmpty)
    }

    @Test func bidiControlAdjacentToMatchOnMultiLineFieldRejectsTheField() {
        #expect(
            FieldLinkScanner.scan("Help:\n\u{202E}https://acme.example/help\n", source: linkScannerTestSource).isEmpty)
    }

    @Test func bidiControlOnAnotherLineStillRejectsTheWholeField() {
        // Line breaks do not split the field into independent trust units.
        let text = "Note \u{202E}reversed\nhttps://acme.example/help\nsupport@acme.example"
        #expect(FieldLinkScanner.scan(text, source: linkScannerTestSource).isEmpty)
    }

    // -- Engine-independent classes --------------------------------------------
    //
    // ICU's `\s` and `\d` are Unicode-aware, so the patterns spell their classes out
    // and these cases pin the result.

    @Test func phoneWithNarrowNoBreakSpacesIsOneSpan() {
        let phone = "+33\u{202F}1\u{202F}23\u{202F}45\u{202F}67\u{202F}89"
        expectExactSpans("Tel \(phone).", [(phone, .phone)])
    }

    @Test func phoneWithNoBreakSpacesIsOneSpan() {
        let phone = "+33\u{00A0}1\u{00A0}23\u{00A0}45\u{00A0}67\u{00A0}89"
        expectExactSpans("Tel \(phone).", [(phone, .phone)])
    }

    @Test func phoneWithFigureAndThinSpacesIsOneSpan() {
        let phone = "+33\u{2007}1\u{2009}23\u{2007}45\u{2009}67\u{2007}89"
        expectExactSpans("Tel \(phone).", [(phone, .phone)])
    }

    @Test func otherUnicodeSpacesEndAPhoneMatch() {
        // Only five horizontal spaces join digit groups; U+2002 splits off the country code.
        expectExactSpans("+1\u{2002}800 555 1234", [("800 555 1234", .phone)])
    }

    @Test func phoneSpacedOnlyWithNoBreakSpacesAndNoPlusStaysUnlinked() {
        #expect(FieldLinkScanner.scan("Ref 555\u{00A0}123\u{00A0}4567", source: linkScannerTestSource).isEmpty)
    }

    @Test func phoneRunMixingNonAsciiDigitsDoesNotLink() {
        let texts = [
            "Call 0800 555 010\u{1D7D7} now",  // trailing MATHEMATICAL BOLD DIGIT NINE
            "Call \u{FF11}800-555-0100 now",  // leading fullwidth one
            "Call \u{1D7D7}800-555-0100 now",  // leading MATHEMATICAL BOLD DIGIT NINE
            "Call 555-123-4567\u{0663} now",  // trailing Arabic-Indic three
        ]
        for text in texts {
            #expect(FieldLinkScanner.scan(text, source: linkScannerTestSource).isEmpty, "\(text)")
        }
    }

    @Test func nonAsciiDigitOutsideThePhoneRunKeepsThePhone() {
        let texts = [
            "Ref \u{0663}\u{0664}\u{0665}\n+1 555 123 4567",  // a line break ends the run
            "\u{0663} x +1 555 123 4567",  // a letter ends the run
            "\u{0663}\u{1F600}+1 555 123 4567",  // a supplementary non-run char ends the run
        ]
        for text in texts {
            expectExactSpans(text, [("+1 555 123 4567", .phone)])
        }
    }

    @Test func phoneInsideUrlOrEmailIsNotLinkedTwice() {
        expectExactSpans(
            "https://acme.example/call/555-123-4567",
            [("https://acme.example/call/555-123-4567", .url)]
        )
        expectExactSpans("555-123-4567@acme.example", [("555-123-4567@acme.example", .email)])

        let text = "+1 555 123 4567 https://x.example/555-123-4567 a@b.example +1 555 765 4321"
        let kinds = FieldLinkScanner.scan(text, source: linkScannerTestSource).map { LinkKind($0.intent) }
        #expect(kinds == [.phone, .url, .email, .phone])
    }

    @Test func nonAsciiDigitRunsDoNotLink() {
        let texts = [
            "+\u{0669}\u{0667}\u{0661} \u{0664} \u{0663}\u{0666}\u{0666} \u{0668}\u{0668}\u{0668}\u{0668}",
            "+\u{FF11} \u{FF15}\u{FF15}\u{FF15} \u{FF11}\u{FF12}\u{FF13} \u{FF14}\u{FF15}\u{FF16}\u{FF17}",
        ]
        for text in texts {
            #expect(FieldLinkScanner.scan(text, source: linkScannerTestSource).isEmpty, "\(text)")
        }
    }

    @Test func fieldHazardAllowsOnlyLineBreaksAndTab() {
        for whitespace in ["\n", "\t", "\r\n", "\r\n\r\n"] {
            #expect(!FieldLinkScanner.containsFieldHazard("a\(whitespace)b"))
        }
        for hazard in fieldHazards {
            #expect(FieldLinkScanner.containsFieldHazard("safe\n\(hazard)"), "\(codepoint(hazard)) field")
        }
        #expect(FieldLinkScanner.containsFieldHazard("a\r\r\nb"))
    }

    @Test func renderingHazardStillFlagsLineBreaksAndTab() {
        for whitespace in ["\n", "\r", "\t", "\u{2028}", "\u{2029}"] {
            #expect(
                FieldLinkScanner.containsRenderingHazard("a\(whitespace)b"),
                "\(codepoint(whitespace)) must be a match-level hazard"
            )
        }
    }

    /// Cf, Cc (bar line feed and tab) and separator codepoints that must reject a field.
    private let fieldHazards = [
        "\r", "\u{2028}", "\u{2029}",
        "\u{202E}", "\u{202D}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200B}",
        "\u{200E}", "\u{200F}", "\u{061C}", "\u{FEFF}", "\u{0000}", "\u{0007}", "\u{001B}",
        "\u{000B}", "\u{000C}", "\u{007F}", "\u{0085}",
    ]
}
