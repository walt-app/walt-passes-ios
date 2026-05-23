import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableFormatConstraints")
struct ScannableFormatConstraintsTests {

    @Test func maxPayloadLengthHasValueForEveryFormat() {
        for format in ScannableFormat.allCases {
            #expect(ScannableFormatConstraints.maxPayloadLength(format) > 0)
        }
    }

    @Test func requiredLengthIsSetOnlyForFixedLengthSymbologies() {
        #expect(ScannableFormatConstraints.requiredLength(.ean13) == 13)
        #expect(ScannableFormatConstraints.requiredLength(.upcA) == 12)
        #expect(ScannableFormatConstraints.requiredLength(.code128) == nil)
        #expect(ScannableFormatConstraints.requiredLength(.code39) == nil)
        #expect(ScannableFormatConstraints.requiredLength(.qr) == nil)
    }

    @Test func ean13RejectsLetters() {
        #expect(ScannableFormatConstraints.isAllowedChar(format: .ean13, char: "0"))
        #expect(!ScannableFormatConstraints.isAllowedChar(format: .ean13, char: "A"))
    }

    @Test func code39AcceptsUppercaseAndAllowedPunctuation() {
        #expect(ScannableFormatConstraints.isAllowedChar(format: .code39, char: "A"))
        #expect(ScannableFormatConstraints.isAllowedChar(format: .code39, char: "$"))
        #expect(!ScannableFormatConstraints.isAllowedChar(format: .code39, char: "a"))
    }

    @Test func qrAlphanumericCharsetMatchesIso18004() {
        for c in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:" {
            #expect(ScannableFormatConstraints.isQrAlphanumericChar(c), "\(c) should be alphanumeric")
        }
        #expect(!ScannableFormatConstraints.isQrAlphanumericChar("a"))
        #expect(!ScannableFormatConstraints.isQrAlphanumericChar("@"))
    }

    @Test func validateStructuralAcceptsValidEan13() {
        // "1234567890120" — happy-path EAN-13 used by passes-android's validator tests.
        #expect(ScannableFormatConstraints.validateStructural(format: .ean13, payload: "1234567890120") == nil)
    }

    @Test func validateStructuralRejectsBadEan13CheckDigit() {
        // "1234567890121" — one-off-by-one check digit, also from passes-android's tests.
        let result = ScannableFormatConstraints.validateStructural(format: .ean13, payload: "1234567890121")
        #expect(result == .invalidCheckDigit(format: .ean13))
    }

    @Test func validateStructuralAcceptsValidUpcA() {
        // "036000291452" — a known-valid UPC-A.
        #expect(ScannableFormatConstraints.validateStructural(format: .upcA, payload: "036000291452") == nil)
    }

    @Test func validateStructuralRejectsBadUpcACheckDigit() {
        let result = ScannableFormatConstraints.validateStructural(format: .upcA, payload: "036000291450")
        #expect(result == .invalidCheckDigit(format: .upcA))
    }

    @Test func validateStructuralIsNoopForVariableLengthSymbologies() {
        #expect(ScannableFormatConstraints.validateStructural(format: .code128, payload: "ABC123") == nil)
        #expect(ScannableFormatConstraints.validateStructural(format: .code39, payload: "ABC123") == nil)
        #expect(ScannableFormatConstraints.validateStructural(format: .qr, payload: "anything") == nil)
    }
}
