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

    @Test func armsAreReachableViaSwitch() {
        let status: SignatureStatus = .appleVerified
        let branch: String
        switch status {
        case .unsigned: branch = "unsigned"
        case .selfSigned: branch = "selfSigned"
        case .appleVerified: branch = "appleVerified"
        case .certChainIncomplete: branch = "certChainIncomplete"
        }
        #expect(branch == "appleVerified")
    }
}
