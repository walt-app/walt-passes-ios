import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableFormat")
struct ScannableFormatTests {

    @Test func allCasesAreReachable() {
        // CaseIterable surface: removing a case fails this expectation.
        #expect(ScannableFormat.allCases.count == 7)
        #expect(
            Set(ScannableFormat.allCases) == [
                .code128, .ean13, .upcA, .code39, .qr, .pdf417, .aztec,
            ])
    }

    @Test func onlyTheDecodeOnlyPairIsNotCreatable() {
        // ios-pjs.15 transitional state: pdf417/aztec decode but have no writer until
        // ios-pjs.16 wires the arms and empties the decode-only set.
        #expect(!ScannableFormat.pdf417.isCreatable())
        #expect(!ScannableFormat.aztec.isCreatable())
        for format: ScannableFormat in [.code128, .ean13, .upcA, .code39, .qr] {
            #expect(format.isCreatable(), "\(format) should stay creatable")
        }
    }
}
