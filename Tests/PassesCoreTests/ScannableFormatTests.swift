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

    @Test func everyRosterMemberIsCreatable() {
        // ios-pjs.16 wired the Aztec/PDF417 writers and emptied the decode-only set;
        // the mechanism stays for a future decode-first roster addition.
        for format in ScannableFormat.allCases {
            #expect(format.isCreatable(), "\(format) should be creatable")
        }
    }

    @Test func onlyTheByteCapable2DFormatsCanCarryActionablePayloads() {
        // The C4 gate keys off this predicate (ios-pjs.17, wlt-9o3x analogue): QR,
        // PDF417 and Aztec carry URIs a scanner may act on; the 1D trio does not.
        #expect(ScannableFormat.qr.canCarryActionablePayload())
        #expect(ScannableFormat.pdf417.canCarryActionablePayload())
        #expect(ScannableFormat.aztec.canCarryActionablePayload())
        for format: ScannableFormat in [.code128, .ean13, .upcA, .code39] {
            #expect(!format.canCarryActionablePayload(), "\(format) is not actionable")
        }
    }
}
