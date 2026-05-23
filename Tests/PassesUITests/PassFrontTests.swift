import Testing

@testable import PassesUI

@Suite("PassesUI scaffold")
struct PassFrontTests {

    @Test func passFrontViewCarriesId() {
        let view = PassFrontView(passId: "p-1", title: "Library card")
        #expect(view.passId == "p-1")
        #expect(view.title == "Library card")
    }
}
