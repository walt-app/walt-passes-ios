import Foundation
import Testing
@_spi(CMS) import X509

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

    @Test func sha1BareRSASignerIsAppleVerified() throws {
        // Regression guard for ipass-c8p. A SignerInfo carrying digestAlgorithm=SHA-1 with the bare
        // `rsaEncryption` signatureAlgorithm - the shape Apple PassKit ships and the shape of the
        // pass reported in walt-app/walt-passes-android#176 - was left unrewritten by the
        // normalizer, so `AlgorithmIdentifier(digestAlgorithmFor:)` threw and the pass read
        // Tampered. Red before the SHA-1 arm in `combinedRSA(forDigest:)`, green after.
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
        // The security half of ipass-c8p: rewriting the algorithm OID must not let a mutated
        // manifest verify. The signed messageDigest no longer matches the manifest's SHA-1.
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

    @Test func normalizerRewritesSHA1BareRSAToCombinedOID() throws {
        // Keeps the two tests above from going vacuous: asserts the blob really is the bare-RSA
        // shape the normalizer must rewrite, rather than one swift-certificates already accepted.
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        let leaf = try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root)
        let signature = try SignatureTestSupport.signSHA1BareRSA(manifestBytes: manifest, signer: leaf)
        #expect(normalizeCMSSignatureAlgorithm(signature) != signature)
    }

    @Test func wireOrderSignedAttrsVerify() throws {
        // Regression guard for ipass-10g (Android wpass-x70, GH walt-passes-android#176). The
        // signedAttrs SET is signed in wire rather than sorted DER order, which swift-asn1 refuses to
        // parse, so the strict path reports a structurally invalid CMS block. Apple Wallet, Google
        // Wallet and OpenSSL all accept these passes. Red before the fallback, green after.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf
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

    @Test func stockLibraryStillRejectsWireOrderSignedAttrs() async throws {
        // Anti-vacuity control, mirroring Android's. If a future swift-certificates release accepted
        // wire-order signedAttrs on its own, the test above would pass without exercising the
        // fallback at all and would silently stop guarding anything. This fails when that happens.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf
        )
        let result = await CMS.isValidSignature(
            dataBytes: manifest,
            signatureBytes: signature,
            trustRoots: CertificateStore([root.certificate])
        ) {
            RFC5280Policy(validationTime: Date())
        }
        guard case .failure(.invalidCMSBlock) = result else {
            Issue.record("stock swift-certificates now accepts wire-order signedAttrs: \(result)")
            return
        }
    }

    @Test func libraryVerifiesOverDataBytesWhenSignedAttrsAbsent() async throws {
        // Pins the library behaviour the fallback's whole design rests on: with no signedAttrs, the
        // signature is checked directly against `dataBytes`. If a future release required signedAttrs
        // to be present, the fallback would stop working, and this fails loudly rather than the
        // regression above failing for an unexplained reason.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let arbitrary = [UInt8]("not a manifest, just some bytes".utf8)
        // `sign` without a signingTime emits a SignerInfo with no signedAttrs at all.
        let signature = try SignatureTestSupport.sign(manifestBytes: arbitrary, signer: leaf)
        let result = await CMS.isValidSignature(
            dataBytes: arbitrary,
            signatureBytes: signature,
            trustRoots: CertificateStore([root.certificate])
        ) {
            RFC5280Policy(validationTime: Date())
        }
        guard case .success = result else {
            Issue.record("swift-certificates no longer verifies over dataBytes without signedAttrs: \(result)")
            return
        }
    }

    @Test func wireOrderSignedAttrsWithTamperedManifestFailsClosed() throws {
        // The security property behind ipass-10g: the fallback strips signedAttrs, which also strips
        // the one signed attribute the library validates, so it re-does the messageDigest comparison
        // itself. Without that, a mutated manifest would keep an intact signature over its untouched
        // attributes and verify.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8),
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        if case .failed = result { return }
        Issue.record("wire-order fallback accepted a tampered manifest: \(result)")
    }

    @Test func wireOrderSignedAttrsRejectedUnderStrictConfig() throws {
        // The fallback routes through the same config gating as the strict path: a chain that does
        // not reach a bundled anchor is refused when self-signed certificates are not accepted.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf
        )
        let unrelated = try SignatureTestSupport.makeRoot(commonName: "Unrelated")
        #expect(
            SignatureTestSupport.verify(
                signatureBytes: signature,
                manifestBytes: manifest,
                config: .strict,
                trustAnchors: [unrelated.certificate],
                knownIntermediates: []
            ) == .failed(.signatureCryptoFailure)
        )
        // Same blob, lenient config: recovered as an incomplete chain rather than as tampering,
        // which is the arm Android's real reported pass landed on.
        #expect(
            SignatureTestSupport.verify(
                signatureBytes: signature,
                manifestBytes: manifest,
                config: ParserConfig(),
                trustAnchors: [unrelated.certificate],
                knownIntermediates: []
            ) == .ok(.certChainIncomplete)
        )
    }

    @Test func wireOrderWithDuplicateMessageDigestFailsClosed() throws {
        // The fallback treats the messageDigest attribute as *the* digest the signature commits to,
        // so it requires exactly one. Two of them, even both correct, must fail closed rather than
        // letting a first-match guess stand in.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf,
            shape: .reversedWithDuplicateMessageDigest
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        if case .failed = result { return }
        Issue.record("wire-order fallback accepted a duplicate messageDigest: \(result)")
    }

    @Test func wireOrderMultiSignerEnvelopeFailsClosed() throws {
        // The single-signer floor, which the fallback alone enforces. Both signatures here are
        // genuine, so nothing is cryptographically wrong with the envelope; it is refused because the
        // trust claim is stated for one signer. swift-certificates' own "Too many signatures" check
        // cannot help: the fallback's rebuild emits exactly one SignerInfo, so the library never sees
        // the second one. Mutation-tested - relaxing the guard makes this verify.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signWithWireOrderSignedAttrs(
            manifestBytes: manifest,
            signer: leaf,
            shape: .reversedWithTwoSigners
        )
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        if case .failed = result { return }
        Issue.record("wire-order fallback accepted a multi-signer envelope: \(result)")
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
