import Foundation
import Testing

@testable import PassesCore

/// Behavior lock for `ScannableCardInputValidator`. Pins per-format charset, length, bidi /
/// control rejection, and EAN-13 / UPC-A check-digit rules. Companion to the surface lock in
/// `ScannableCardTests`, which covers the shape of the result type.
@Suite("ScannableCardInputValidator")
struct ScannableCardInputValidatorTests {
    private let id = ScannableCardId("test")
    private let now = PassInstant(epochMillis: 1_800_000_000_000)

    // ---- per-format success ----

    @Test func code128HappyPath() {
        let result = validate(payload: "ABC123 xyz", format: .code128)
        assertSuccessWithPayload(result, expected: "ABC123 xyz")
    }

    @Test func code39HappyPath() {
        let result = validate(payload: "ABC-123 +%/.$", format: .code39)
        assertSuccessWithPayload(result, expected: "ABC-123 +%/.$")
    }

    @Test func ean13HappyPathWithValidCheckDigit() {
        // Check digit 8 for data 123456789012 (weights from right: 3,1,3,1...).
        let result = validate(payload: "1234567890128", format: .ean13)
        assertSuccessWithPayload(result, expected: "1234567890128")
    }

    @Test func ean13HappyPathRealWorldBarcode() {
        // Real EAN-13 (check digit 1); guards against the flipped-weights regression.
        let result = validate(payload: "4006381333931", format: .ean13)
        assertSuccessWithPayload(result, expected: "4006381333931")
    }

    @Test func upcAHappyPathWithValidCheckDigit() {
        let result = validate(payload: "123456789012", format: .upcA)
        assertSuccessWithPayload(result, expected: "123456789012")
    }

    @Test func qrHappyPathAcceptsUtf8() {
        let result = validate(payload: "https://example.org/é/👍", format: .qr)
        assertSuccessWithPayload(result, expected: "https://example.org/é/👍")
    }

    // ---- length caps ----

    @Test func code128TooLong() {
        let payload = String(repeating: "A", count: 81)
        let rejection = expectPayloadRejection(payload, format: .code128)
        guard case .tooLong(let actual, let max) = rejection else {
            Issue.record("expected .tooLong, got \(rejection)")
            return
        }
        #expect(actual == 81)
        #expect(max == 80)
    }

    @Test func code39TooLong() {
        let rejection = expectPayloadRejection(String(repeating: "A", count: 81), format: .code39)
        if case .tooLong = rejection { return }
        Issue.record("expected .tooLong, got \(rejection)")
    }

    @Test func qrTooLong() {
        let rejection = expectPayloadRejection(String(repeating: "x", count: 2001), format: .qr)
        if case .tooLong = rejection { return }
        Issue.record("expected .tooLong, got \(rejection)")
    }

    // ---- charset violations ----

    @Test func code128RejectsNonAsciiBecauseOfCharset() {
        let rejection = expectPayloadRejection("ABCé", format: .code128)
        guard case .wrongCharset(let format, let char) = rejection else {
            Issue.record("expected .wrongCharset, got \(rejection)")
            return
        }
        #expect(format == .code128)
        #expect(char == "é")
    }

    @Test func code39RejectsLowercaseLetters() {
        let rejection = expectPayloadRejection("abc", format: .code39)
        if case .wrongCharset = rejection { return }
        Issue.record("expected .wrongCharset, got \(rejection)")
    }

    @Test func ean13RejectsLetters() {
        let rejection = expectPayloadRejection("12345678A0120", format: .ean13)
        if case .wrongCharset = rejection { return }
        Issue.record("expected .wrongCharset, got \(rejection)")
    }

    @Test func upcARejectsLetters() {
        let rejection = expectPayloadRejection("12345A789012", format: .upcA)
        if case .wrongCharset = rejection { return }
        Issue.record("expected .wrongCharset, got \(rejection)")
    }

    // ---- bidi / control rejection across all formats ----

    @Test func code128BidiCharRejected() {
        let rejection = expectPayloadRejection("AB\u{202E}C", format: .code128)
        #expect(rejection == .containsBidiChar)
    }

    @Test func code39BidiCharRejected() {
        let rejection = expectPayloadRejection("AB\u{202E}C", format: .code39)
        #expect(rejection == .containsBidiChar)
    }

    @Test func ean13BidiCharRejected() {
        let rejection = expectPayloadRejection("1234567\u{202E}890120", format: .ean13)
        #expect(rejection == .containsBidiChar)
    }

    @Test func upcABidiCharRejected() {
        let rejection = expectPayloadRejection("12345\u{202E}789012", format: .upcA)
        #expect(rejection == .containsBidiChar)
    }

    @Test func qrBidiCharRejected() {
        let rejection = expectPayloadRejection("hello\u{202E}world", format: .qr)
        #expect(rejection == .containsBidiChar)
    }

    @Test func nullByteRejectedAsControlChar() {
        let rejection = expectPayloadRejection("AB\u{0000}C", format: .code128)
        #expect(rejection == .containsControlChar)
    }

    @Test func qrNullByteRejectedAsControlChar() {
        let rejection = expectPayloadRejection("hi\u{0000}there", format: .qr)
        #expect(rejection == .containsControlChar)
    }

    // ---- trim / empty ----

    @Test func payloadIsTrimmedBeforeValidation() {
        let result = validate(payload: "  ABC  ", format: .code128)
        assertSuccessWithPayload(result, expected: "ABC")
    }

    @Test func whitespaceOnlyPayloadIsEmpty() {
        let rejection = expectPayloadRejection("   ", format: .code128)
        #expect(rejection == .empty)
    }

    @Test func emptyPayloadRejected() {
        let rejection = expectPayloadRejection("", format: .code128)
        #expect(rejection == .empty)
    }

    // ---- EAN-13 structural ----

    @Test func ean13WrongLengthRejected() {
        let rejection = expectPayloadRejection("123456789012", format: .ean13)
        guard case .wrongLength(let actual, let required, let format) = rejection else {
            Issue.record("expected .wrongLength, got \(rejection)")
            return
        }
        #expect(actual == 12)
        #expect(required == 13)
        #expect(format == .ean13)
    }

    @Test func ean13InvalidCheckDigitRejected() {
        let rejection = expectPayloadRejection("1234567890121", format: .ean13)
        guard case .invalidCheckDigit(let format) = rejection else {
            Issue.record("expected .invalidCheckDigit, got \(rejection)")
            return
        }
        #expect(format == .ean13)
    }

    @Test func ean13FlippedWeightCheckDigitRejected() {
        // Regression: 1234567890120 validates only under the old, flipped weights
        // (rightmost data digit weighted 1 instead of 3). It must now be rejected.
        let rejection = expectPayloadRejection("1234567890120", format: .ean13)
        guard case .invalidCheckDigit(let format) = rejection else {
            Issue.record("expected .invalidCheckDigit, got \(rejection)")
            return
        }
        #expect(format == .ean13)
    }

    @Test func ean13LongLengthRejectedAsWrongLength() {
        let rejection = expectPayloadRejection("12345678901234", format: .ean13)
        guard case .wrongLength(let actual, let required, let format) = rejection else {
            Issue.record("expected .wrongLength, got \(rejection)")
            return
        }
        #expect(actual == 14)
        #expect(required == 13)
        #expect(format == .ean13)
    }

    // ---- UPC-A structural ----

    @Test func upcAShortLengthRejected() {
        let rejection = expectPayloadRejection("12345678901", format: .upcA)
        guard case .wrongLength(let actual, let required, _) = rejection else {
            Issue.record("expected .wrongLength, got \(rejection)")
            return
        }
        #expect(actual == 11)
        #expect(required == 12)
    }

    @Test func upcALongLengthRejectedAsWrongLength() {
        // Fixed-length symbology: a 13-digit input must surface wrongLength (NOT tooLong),
        // so the consumer has a single arm to render for "wrong digit count" regardless of
        // whether the user typed too few or too many.
        let rejection = expectPayloadRejection("1234567890128", format: .upcA)
        guard case .wrongLength(let actual, let required, let format) = rejection else {
            Issue.record("expected .wrongLength, got \(rejection)")
            return
        }
        #expect(actual == 13)
        #expect(required == 12)
        #expect(format == .upcA)
    }

    @Test func upcAInvalidCheckDigitRejected() {
        let rejection = expectPayloadRejection("123456789013", format: .upcA)
        if case .invalidCheckDigit = rejection { return }
        Issue.record("expected .invalidCheckDigit, got \(rejection)")
    }

    // ---- label ----

    @Test func labelEmptyRejected() {
        let result = validateInput(payload: "ABC", format: .code128, label: "")
        guard case .invalidLabel(let reason) = result else {
            Issue.record("expected .invalidLabel, got \(result)")
            return
        }
        #expect(reason == .empty)
    }

    @Test func labelBidiCharRejected() {
        let result = validateInput(payload: "ABC", format: .code128, label: "Card\u{202E}")
        guard case .invalidLabel(let reason) = result else {
            Issue.record("expected .invalidLabel, got \(result)")
            return
        }
        #expect(reason == .containsBidiChar)
    }

    @Test func labelControlCharRejected() {
        let result = validateInput(payload: "ABC", format: .code128, label: "Card\u{0007}")
        guard case .invalidLabel(let reason) = result else {
            Issue.record("expected .invalidLabel, got \(result)")
            return
        }
        #expect(reason == .containsControlChar)
    }

    @Test func labelTooLongRejected() {
        let long = String(repeating: "L", count: 65)
        let result = validateInput(payload: "ABC", format: .code128, label: long)
        guard case .invalidLabel(let reason) = result else {
            Issue.record("expected .invalidLabel, got \(result)")
            return
        }
        guard case .tooLong(let actual, let max) = reason else {
            Issue.record("expected .tooLong, got \(reason)")
            return
        }
        #expect(actual == 65)
        #expect(max == 64)
    }

    @Test func labelExactlyAtCapAccepted() {
        let result = validateInput(payload: "ABC", format: .code128, label: String(repeating: "L", count: 64))
        if case .success = result { return }
        Issue.record("expected .success, got \(result)")
    }

    @Test func whitespaceOnlyLabelIsEmpty() {
        let result = validateInput(payload: "ABC", format: .code128, label: "   ")
        guard case .invalidLabel(let reason) = result else {
            Issue.record("expected .invalidLabel, got \(result)")
            return
        }
        #expect(reason == .empty)
    }

    // ---- trim semantics on success path ----

    @Test func successCardCarriesTrimmedPayloadNotRaw() {
        let result = validate(payload: "  hello  ", format: .code128)
        guard case .success(let card) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(card.payload == "hello")
        #expect(!card.payload.contains(" "))
    }

    @Test func successCardCarriesTrimmedLabelNotRaw() {
        let result = validateInput(payload: "ABC", format: .code128, label: "  My Card  ")
        guard case .success(let card) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(card.label == "My Card")
    }

    @Test func successCardCarriesCallerIdAndTimestamp() {
        let result = validate(payload: "ABC", format: .code128)
        guard case .success(let card) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(card.id == id)
        #expect(card.createdAt == now)
    }

    // ---- helpers ----

    private func validate(payload: String, format: ScannableFormat) -> ScannableCardCreateResult {
        validateInput(payload: payload, format: format, label: "Card")
    }

    private func validateInput(
        payload: String,
        format: ScannableFormat,
        label: String
    ) -> ScannableCardCreateResult {
        ScannableCardInputValidator.validate(
            input: ScannableCardCreateInput(payload: payload, format: format, label: label),
            id: id,
            createdAt: now
        )
    }

    private func expectPayloadRejection(_ payload: String, format: ScannableFormat) -> PayloadRejection {
        let result = validate(payload: payload, format: format)
        guard case .invalidPayload(let reason) = result else {
            Issue.record("expected .invalidPayload, got \(result)")
            return .empty
        }
        return reason
    }

    private func assertSuccessWithPayload(_ result: ScannableCardCreateResult, expected: String) {
        guard case .success(let card) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(card.payload == expected)
    }
}
