import Foundation
import Testing

@testable import PassesCore

@Suite("ParseResult")
struct ParseResultTests {

    @Test func parseResultArmsAreReachableViaSwitch() {
        let result: ParseResult = .malformed(reason: .notAZipArchive)
        let branch: String
        switch result {
        case .success: branch = "success"
        case .tampered: branch = "tampered"
        case .malformed: branch = "malformed"
        case .unsupported: branch = "unsupported"
        }
        #expect(branch == "malformed")
    }

    @Test func tamperReasonArmsAreAllConstructible() {
        let reasons: [TamperReason] = [
            .manifestSignatureMismatch,
            .fileHashMismatch,
            .signatureCryptoFailure,
            .signerCertificateMissing,
            .signatureUntrusted,
        ]
        #expect(Set(reasons).count == reasons.count)
    }

    @Test func malformedReasonArmsAreAllConstructible() {
        let reasons: [MalformedReason] = [
            .notAZipArchive,
            .missingPassJson,
            .missingManifest,
            .invalidPassJson,
            .invalidManifest,
            .invalidStrings,
            .resourceLimitExceeded(limit: .jsonDepth),
        ]
        #expect(reasons.count == 7)
    }

    @Test func unsupportedReasonArmsAreAllConstructible() {
        let reasons: [UnsupportedReason] = [
            .formatVersion(version: 2),
            .unknownPassStyle(raw: "nfcPass"),
            .encryptedArchive,
        ]
        #expect(reasons.count == 3)
    }

    @Test func resourceLimitHasAllEightBuckets() {
        #expect(ResourceLimit.allCases.count == 8)
        #expect(
            Set(ResourceLimit.allCases) == [
                .archiveSize, .entryCount, .entrySize,
                .jsonDepth, .jsonStringSize, .imagePixelCount, .localeCount, .inflatedSize,
            ]
        )
    }
}
