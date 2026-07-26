import Testing

@testable import PassesCore

@Suite("ParseResult.toFailureKind")
struct ParseFailureKindTests {

    @Test func successIsNotAFailure() {
        let result = ParseResult.success(pass: Fixtures.pass, signatureStatus: .appleVerified)
        #expect(result.toFailureKind() == nil)
    }

    @Test func tamperedFlattensToTampered() {
        for reason: TamperReason in [
            .manifestSignatureMismatch, .fileHashMismatch,
            .signatureCryptoFailure, .signerCertificateMissing,
        ] {
            #expect(ParseResult.tampered(reason: reason).toFailureKind() == .tampered)
        }
    }

    @Test func structuralMalformedFlattensToMalformed() {
        for reason: MalformedReason in [
            .notAZipArchive, .missingPassJson, .missingManifest,
            .invalidPassJson, .invalidManifest, .invalidStrings,
        ] {
            #expect(ParseResult.malformed(reason: reason).toFailureKind() == .malformed)
        }
    }

    @Test func resourceLimitLiftsOutOfMalformed() {
        for limit in ResourceLimit.allCases {
            let result = ParseResult.malformed(reason: .resourceLimitExceeded(limit: limit))
            #expect(result.toFailureKind() == .resourceLimitExceeded)
        }
    }

    @Test func unsupportedFlattensToUnsupported() {
        for reason: UnsupportedReason in [
            .formatVersion(version: 2), .unknownPassStyle(raw: "x"), .encryptedArchive,
        ] {
            #expect(ParseResult.unsupported(reason: reason).toFailureKind() == .unsupported)
        }
    }

    private enum Fixtures {
        static let pass = Pass(
            type: .generic,
            serialNumber: "0",
            description: "fixture",
            organizationName: "Org",
            colors: PassColors(
                foreground: ColorValue(rgb: 0),
                background: ColorValue(rgb: 0xFFFFFF),
                label: ColorValue(rgb: 0x444444)
            ),
            frontFields: PassFields(
                primary: [PassField(key: "p", label: nil, value: "value")]
            ),
            backFields: []
        )
    }
}
