import Foundation
import Testing

@testable import PassesCore

@Suite("SignatureStatusKind")
struct SignatureStatusKindTests {

    // Drift detector: adding a SignatureStatus arm without extending SignatureStatusKind
    // fails the build inside `toKind()`. This test pins the current arm count.
    @Test func toKindMapsEveryArm() {
        #expect(SignatureStatus.unsigned.toKind() == .unsigned)
        #expect(SignatureStatus.selfSigned.toKind() == .selfSigned)
        #expect(SignatureStatus.appleVerified.toKind() == .appleVerified)
        #expect(SignatureStatus.certChainIncomplete.toKind() == .certChainIncomplete)
    }

    @Test func kindHasFourCases() {
        #expect(SignatureStatusKind.allCases.count == 4)
    }
}
