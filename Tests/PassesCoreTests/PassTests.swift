import Foundation
import Testing

@testable import PassesCore

@Suite("Pass")
struct PassTests {

    @Test func equalityRequiresAllFields() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(
            Pass(id: "1", label: "a", issuer: "i", expiresAt: date)
                == Pass(id: "1", label: "a", issuer: "i", expiresAt: date)
        )
        #expect(
            Pass(id: "1", label: "a") != Pass(id: "2", label: "a")
        )
    }
}
