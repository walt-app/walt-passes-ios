import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableFormat")
struct ScannableFormatTests {

    @Test func allCasesAreReachable() {
        // CaseIterable surface: removing a case fails this expectation.
        #expect(ScannableFormat.allCases.count == 5)
        #expect(Set(ScannableFormat.allCases) == [.code128, .ean13, .upcA, .code39, .qr])
    }
}
