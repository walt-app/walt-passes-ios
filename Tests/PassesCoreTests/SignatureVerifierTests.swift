import Foundation
import Testing
import X509

@testable import PassesCore

@Suite("SignatureVerifier")
struct SignatureVerifierTests {

    private let manifest = [UInt8]("{\"pass.json\":\"abc\"}".utf8)

    @Test func validChainReachingAnchorIsAppleVerified() throws {
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func intermediateSuppliedSeparatelyStillReachesAnchor() throws {
        // Leaf signed by an intermediate; the intermediate is NOT embedded in the CMS but is
        // provided as a known intermediate, mirroring Android's WWDR-supplement path.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let intermediate = try SignatureTestSupport.makeIntermediate(commonName: "Intermediate", issuer: root)
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: intermediate)
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: [intermediate.certificate]
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func selfSignedLeafWithLenientConfigIsSelfSigned() throws {
        // The signer is a self-issued root; with no matching trust anchor it cannot reach Apple.
        let root = try SignatureTestSupport.makeRoot(commonName: "SelfSigner")
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: root)
        let unrelated = try SignatureTestSupport.makeRoot(commonName: "Unrelated")
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [unrelated.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.selfSigned))
    }

    @Test func nonSelfIssuedSignerWithLenientConfigIsCertChainIncomplete() throws {
        // Leaf issued by a root that is NOT a trust anchor: signer is not self-issued, so the
        // lenient path classifies as certChainIncomplete.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        let unrelated = try SignatureTestSupport.makeRoot(commonName: "Unrelated")
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [unrelated.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.certChainIncomplete))
    }

    @Test func selfSignedRejectedUnderStrict() throws {
        let root = try SignatureTestSupport.makeRoot(commonName: "SelfSigner")
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: root)
        let unrelated = try SignatureTestSupport.makeRoot(commonName: "Unrelated")
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: .strict,
            trustAnchors: [unrelated.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.signatureCryptoFailure))
    }

    @Test func tamperedManifestFailsVerification() throws {
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        // Verify against different manifest bytes than were signed.
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test func realAppleSignedPkpassIsAppleVerified() throws {
        // Regression guard for walt-passes-ios#31. The fixture's CMS SignerInfo uses the bare
        // `rsaEncryption` OID for `signatureAlgorithm` (digest conveyed separately in
        // `digestAlgorithm`), a wire shape Apple PassKit ships and swift-certificates 1.19.x does
        // not recognize. Runs the PRODUCTION verifier path (bundled Apple anchors), not the test
        // seam: leaf -> WWDR G4 (embedded) -> Apple Root CA (bundled). Red before the
        // `normalizeCMSSignatureAlgorithm` pre-pass (returns `.manifestSignatureMismatch`), green
        // after. See `Fixtures/apple-signed/README.md` for provenance and shelf life.
        let fixture = try AppleSignedFixture.load()
        let result = verifySignature(
            signatureBytes: fixture.signature,
            manifestBytes: fixture.manifest,
            config: ParserConfig()
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func realAppleSignedPkpassWithTamperedManifestStillFails() throws {
        // Locks the security property behind the walt-passes-ios#31 fix: the bare-rsaEncryption
        // normalization must not let a mutated manifest verify. Same real bare-RSA blob as the
        // green case, but one manifest byte flipped, so the signed messageDigest no longer matches.
        let fixture = try AppleSignedFixture.load()
        var tampered = fixture.manifest
        tampered[tampered.count / 2] ^= 0x01
        let result = verifySignature(
            signatureBytes: fixture.signature,
            manifestBytes: tampered,
            config: ParserConfig()
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

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

    @Test func garbageSignatureBlobIsCryptoFailure() {
        let result = SignatureTestSupport.verify(
            signatureBytes: [0x00, 0x01, 0x02, 0x03],
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [],
            knownIntermediates: []
        )
        // A non-CMS blob fails as a crypto / structural failure (never throws out).
        if case .failed = result { return }
        Issue.record("expected a failed result, got \(result)")
    }
}

/// Real Apple-signed pkpass manifest + detached CMS, loaded from bundled test resources.
private struct AppleSignedFixture {
    let manifest: [UInt8]
    let signature: [UInt8]

    static func load() throws -> AppleSignedFixture {
        AppleSignedFixture(
            manifest: try bytes(resource: "manifest", ext: "json"),
            signature: try bytes(resource: "signature", ext: nil)
        )
    }

    private static func bytes(resource: String, ext: String?) throws -> [UInt8] {
        guard
            let url = Bundle.module.url(
                forResource: resource,
                withExtension: ext,
                subdirectory: "Fixtures/apple-signed"
            )
        else {
            throw FixtureError.missing("\(resource).\(ext ?? "")")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    enum FixtureError: Error { case missing(String) }
}
