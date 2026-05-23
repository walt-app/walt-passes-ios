import Foundation
import Testing

@testable import PassesCore

@Suite("PassType")
struct PassTypeTests {
    @Test func allFiveStylesPresent() {
        let cases = Set(PassType.allCases)
        #expect(cases == [.boardingPass, .eventTicket, .coupon, .storeCard, .generic])
    }
}
