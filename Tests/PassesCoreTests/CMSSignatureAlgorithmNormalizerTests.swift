import Foundation
import Testing

@testable import PassesCore

/// The `normalizeCMSSignatureAlgorithm` pre-pass, driven through the test-only verifier seam with
/// synthesized RSA signers. The real Apple-signed fixtures run in `SignatureVerifierTests`.
@Suite("CMSSignatureAlgorithmNormalizer")
struct CMSSignatureAlgorithmNormalizerTests {

    private let manifest = [UInt8]("{\"pass.json\":\"abc\"}".utf8)

    @Test func normalizerLeavesNonBareRSABlobsByteIdentical() throws {
        // The blast-radius guarantee: the normalizer only rewrites bare-rsaEncryption SignerInfos
        // and returns everything else verbatim. Non-DER garbage and a valid ECDSA (combined-OID)
        // CMS blob must both round-trip unchanged.
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02]
        #expect(normalizeCMSSignatureAlgorithm(garbage) == garbage)

        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let ecdsaBlob = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        #expect(normalizeCMSSignatureAlgorithm(ecdsaBlob) == ecdsaBlob)

        // Sanity: the bare-RSA fixture IS rewritten, so the round-trip checks above are meaningful.
        let fixture = try AppleSignedFixture.load()
        #expect(normalizeCMSSignatureAlgorithm(fixture.signature) != fixture.signature)
    }

    @Test func sha1BareRSASignerIsAppleVerified() throws {
        // SHA-1 digest with the bare `rsaEncryption` signatureAlgorithm: without the SHA-1 arm,
        // `AlgorithmIdentifier(digestAlgorithmFor:)` throws and a sound pass reads Tampered.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(manifestBytes: manifest, signer: leaf)
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func sha1BareRSAWithTamperedManifestStillFails() throws {
        // Rewriting the algorithm OID must not let a mutated manifest verify.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(manifestBytes: manifest, signer: leaf)
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test func sha1WithAbsentDigestParametersIsAppleVerified() throws {
        // The other legal SHA-1 digestAlgorithm encoding, parameters absent. Only SHA-1 maps to a
        // NULL-carrying expectation, so this shape failed a comparison other digests pass.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: .absent
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func sha1WithAbsentDigestParametersAndTamperedManifestFails() throws {
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: .absent
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test(arguments: [
        SignatureTestSupport.DigestParameters.absentInSignerInfoOnly,
        SignatureTestSupport.DigestParameters.absentInDeclaredOnly,
    ])
    func sha1WithMixedDigestParametersIsAppleVerified(
        shape: SignatureTestSupport.DigestParameters
    ) throws {
        // The SignerInfo and the SignedData digestAlgorithms SET each carry their own parameter
        // encoding, and nothing requires an issuer to use the same one at both levels. The library
        // checks them separately, so a rewrite has to fix whichever side is absent rather than only
        // the case where both are.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: shape
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func sha1WithMixedDigestParametersAndTamperedManifestFails() throws {
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: .absentInSignerInfoOnly
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test func sha1FixtureShapesDifferOnTheWire() throws {
        // Anti-vacuity: all four parameter encodings must be distinct on the wire, otherwise the
        // absent and mixed tests could be re-running the NULL case.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let shapes: [SignatureTestSupport.DigestParameters] = [
            .explicitNull, .absent, .absentInSignerInfoOnly, .absentInDeclaredOnly,
        ]
        let encodings = try shapes.map { shape in
            try SignatureTestSupport.signSHA1BareRSA(
                manifestBytes: manifest,
                signer: leaf,
                digestParameters: shape
            )
        }
        #expect(Set(encodings).count == shapes.count)
    }

    @Test(arguments: SignatureTestSupport.DigestParameters.allCases)
    func sha256BareRSASignerIsAppleVerified(shape: SignatureTestSupport.DigestParameters) throws {
        // The SHA-2 mirror image of the SHA-1 cases (ipass-vjt). The library derives
        // `.sha256UsingNil`, parameters absent, so an explicit NULL at either level - which is how
        // Tickster signs - failed the same `==` an absent-parameters SHA-1 did. RFC 5754 s2 says
        // receivers MUST accept both encodings.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA256BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: shape
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func sha256WithNullDigestParametersAndTamperedManifestFails() throws {
        // Stripping the NULL must not let a mutated manifest verify.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA256BareRSA(
            manifestBytes: manifest,
            signer: leaf,
            digestParameters: .explicitNull
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test func sha256FixtureShapesDifferOnTheWire() throws {
        // Anti-vacuity, as for SHA-1: the four parameter encodings must be distinct blobs.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let shapes = SignatureTestSupport.DigestParameters.allCases
        let encodings = try shapes.map { shape in
            try SignatureTestSupport.signSHA256BareRSA(
                manifestBytes: manifest,
                signer: leaf,
                digestParameters: shape
            )
        }
        #expect(Set(encodings).count == shapes.count)
    }

    @Test func normalizerCanonicalizesDigestParametersAtBothLevels() throws {
        // For one signer, all four wire shapes must normalize to identical bytes: NULL at both
        // levels for SHA-1, absent at both for SHA-256. Anything less means one level still carries
        // the encoding the library rejects. RSA PKCS#1 v1.5 is deterministic and the signingTime is
        // fixed, so the signature itself does not vary between shapes.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let shapes = SignatureTestSupport.DigestParameters.allCases

        let sha1 = try shapes.map { shape in
            normalizeCMSSignatureAlgorithm(
                try SignatureTestSupport.signSHA1BareRSA(
                    manifestBytes: manifest, signer: leaf, digestParameters: shape))
        }
        #expect(Set(sha1).count == 1)

        let sha256 = try shapes.map { shape in
            normalizeCMSSignatureAlgorithm(
                try SignatureTestSupport.signSHA256BareRSA(
                    manifestBytes: manifest, signer: leaf, digestParameters: shape))
        }
        #expect(Set(sha256).count == 1)
    }

    @Test func normalizerRewritesSHA1BareRSAToCombinedOID() throws {
        // Anti-vacuity: the blob really is the bare-RSA shape the normalizer must rewrite.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(manifestBytes: manifest, signer: leaf)
        #expect(normalizeCMSSignatureAlgorithm(signature) != signature)
    }
}
