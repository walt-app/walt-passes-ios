import Testing
import PassesCore

@testable import PassesUI

@Suite("ExpiredOverlayState.from")
struct ExpiredOverlayStateTests {

    private func makePass(
        expirationDate: PassInstant? = nil,
        voided: Bool = false
    ) -> Pass {
        Pass(
            type: .generic,
            serialNumber: "0",
            description: "fixture",
            organizationName: "Acme",
            expirationDate: expirationDate,
            voided: voided,
            colors: PassColors(
                foreground: ColorValue(rgb: 0x000000),
                background: ColorValue(rgb: 0xFFFFFF),
                label: ColorValue(rgb: 0x444444)
            ),
            frontFields: PassFields(),
            backFields: []
        )
    }

    @Test func passWithoutExpirationOrVoidedIsNone() {
        let state = ExpiredOverlayState.from(pass: makePass(), nowEpochMillis: 1_000)
        if case .none = state {} else {
            Issue.record("expected .none")
        }
    }

    @Test func voidedPassIsVoidedEvenIfNotYetExpired() {
        let state = ExpiredOverlayState.from(
            pass: makePass(expirationDate: PassInstant(epochMillis: 10_000), voided: true),
            nowEpochMillis: 1_000
        )
        #expect(state == .voided)
    }

    @Test func pastExpirationDateIsExpired() {
        let expiration = PassInstant(epochMillis: 500)
        let state = ExpiredOverlayState.from(
            pass: makePass(expirationDate: expiration),
            nowEpochMillis: 1_000
        )
        #expect(state == .expired(at: expiration))
    }

    @Test func expirationEqualToNowIsExpired() {
        let expiration = PassInstant(epochMillis: 1_000)
        let state = ExpiredOverlayState.from(
            pass: makePass(expirationDate: expiration),
            nowEpochMillis: 1_000
        )
        #expect(state == .expired(at: expiration))
    }

    @Test func futureExpirationIsNone() {
        let state = ExpiredOverlayState.from(
            pass: makePass(expirationDate: PassInstant(epochMillis: 5_000)),
            nowEpochMillis: 1_000
        )
        if case .none = state {} else { Issue.record("expected .none") }
    }
}
