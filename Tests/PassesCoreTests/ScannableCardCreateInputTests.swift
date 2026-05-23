import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableCardCreateInput")
struct ScannableCardCreateInputTests {

    @Test func equalityRequiresAllFields() {
        let a = ScannableCardCreateInput(payload: "123", format: .qr, label: "ticket")
        let b = ScannableCardCreateInput(payload: "123", format: .qr, label: "ticket")
        #expect(a == b)
        #expect(a != ScannableCardCreateInput(payload: "123", format: .qr, label: "other"))
        #expect(a != ScannableCardCreateInput(payload: "123", format: .code128, label: "ticket"))
    }
}
