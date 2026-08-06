import Foundation
import Testing

@testable import PassesCore

@Suite("SignatureStatus")
struct SignatureStatusTests {

    @Test func armsAreAllConstructible() {
        let statuses: [SignatureStatus] = [
            .unsigned,
            .selfSigned,
            .appleVerified,
            .certChainIncomplete,
        ]
        #expect(Set(statuses).count == statuses.count)
    }

    /// Switched over values read from an array, not over a literal: a `let` bound to one arm is a
    /// compile-time constant, so the compiler folds the other branches away as dead code and the
    /// test asserts nothing about them.
    @Test func armsAreReachableViaSwitch() {
        let statuses: [SignatureStatus] = [
            .unsigned,
            .selfSigned,
            .appleVerified,
            .certChainIncomplete,
        ]
        let branches = statuses.map { status -> String in
            switch status {
            case .unsigned: return "unsigned"
            case .selfSigned: return "selfSigned"
            case .appleVerified: return "appleVerified"
            case .certChainIncomplete: return "certChainIncomplete"
            }
        }
        #expect(branches == ["unsigned", "selfSigned", "appleVerified", "certChainIncomplete"])
    }
}
