import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableCard")
struct ScannableCardTests {

    @Test func equalityRequiresAllFields() {
        let a = ScannableCard(
            id: ScannableCardId("1"),
            payload: "ABC",
            format: .code128,
            label: "Loyalty",
            createdAt: PassInstant(epochMillis: 100)
        )
        let b = ScannableCard(
            id: ScannableCardId("1"),
            payload: "ABC",
            format: .code128,
            label: "Loyalty",
            createdAt: PassInstant(epochMillis: 100)
        )
        #expect(a == b)

        let differentId = ScannableCard(
            id: ScannableCardId("2"),
            payload: "ABC",
            format: .code128,
            label: "Loyalty",
            createdAt: PassInstant(epochMillis: 100)
        )
        #expect(a != differentId)
    }

    @Test func scannableCardIdWrapsValueSafely() {
        let id = ScannableCardId("abc")
        #expect(id.value == "abc")
        #expect(id == ScannableCardId("abc"))
        #expect(id != ScannableCardId("xyz"))
    }

    @Test func passInstantWrapsEpochMillis() {
        let t = PassInstant(epochMillis: 1_700_000_000_000)
        #expect(t.epochMillis == 1_700_000_000_000)
        #expect(t == PassInstant(epochMillis: 1_700_000_000_000))
    }
}
