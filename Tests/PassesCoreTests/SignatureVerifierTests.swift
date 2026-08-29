import Foundation
import SwiftASN1
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

    @Test func realTicksterSignedPkpassIsAppleVerified() throws {
        // Regression guard for ipass-vjt. Same bare-`rsaEncryption` shape as the Tixly fixture, but
        // Tickster encodes the SHA-256 digest identifier as `SEQUENCE { sha256, NULL }` at both the
        // SignedData and SignerInfo levels, where Apple and Tixly leave the parameters absent.
        // Production verifier path, bundled anchors. Red before the SHA-2 arm of the digest
        // parameter rewrite, green after. See `Fixtures/apple-signed-sha256-null/README.md`.
        let fixture = try AppleSignedFixture.load(.tickster)
        let result = verifySignature(
            signatureBytes: fixture.signature,
            manifestBytes: fixture.manifest,
            config: ParserConfig()
        )
        #expect(result == .ok(.appleVerified))
    }

    @Test func realTicksterSignedPkpassWithTamperedManifestStillFails() throws {
        let fixture = try AppleSignedFixture.load(.tickster)
        var tampered = fixture.manifest
        tampered[tampered.count / 2] ^= 0x01
        let result = verifySignature(
            signatureBytes: fixture.signature,
            manifestBytes: tampered,
            config: ParserConfig()
        )
        #expect(result == .failed(.manifestSignatureMismatch))
    }

    @Test func ticksterFixtureCarriesNullSHA256ParametersAtBothLevels() throws {
        // Anti-vacuity for the fixture itself: a renewal that swapped in an absent-parameters pass
        // would leave the verify test green without exercising the rewrite.
        let fixture = try AppleSignedFixture.load(.tickster)
        let cms = try #require(CMSStructure(signatureBytes: fixture.signature))
        let declared = try #require(cms.declaredDigestAlgorithms)
        #expect(declared.count == 1)
        for identifier in [cms.digestAlgorithm] + declared {
            let fields = try #require(constructedChildren(of: identifier))
            #expect(leadingOID(of: identifier) == CMSOID.sha256)
            #expect(fields.count == 2 && fields[1].identifier == .null)
        }
    }

    @Test func fallbackDeclinesBlobWithoutSignedAttrs() throws {
        // No signedAttrs means the signature already covers the content, so there is no ordering
        // problem to recover from and the fallback must decline rather than build its own binding.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        // `sign` without a signingTime emits a SignerInfo carrying no attributes.
        let signature = try SignatureTestSupport.sign(manifestBytes: manifest, signer: leaf)
        #expect(
            prepareWireOrderFallback(signatureBytes: signature, manifestBytes: manifest) == nil
        )
    }

    @Test func wireOrderSignedAttrsVerify() throws {
        // signedAttrs signed unsorted, which swift-asn1 refuses to parse. Apple Wallet, Google Wallet
        // and OpenSSL all accept these passes.
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
        // Anti-vacuity: if the library ever accepted wire order on its own, the test above would stop
        // exercising the fallback and silently guard nothing.
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
            RFC5280Policy()
        }
        guard case .failure(.invalidCMSBlock) = result else {
            Issue.record("stock swift-certificates now accepts wire-order signedAttrs: \(result)")
            return
        }
    }

    @Test func libraryVerifiesOverDataBytesWhenSignedAttrsAbsent() async throws {
        // Pins the behaviour the fallback's design rests on: with no signedAttrs the signature is
        // checked directly against `dataBytes`. A release tightening this must fail here, legibly.
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
            RFC5280Policy()
        }
        guard case .success = result else {
            Issue.record("swift-certificates no longer verifies over dataBytes without signedAttrs: \(result)")
            return
        }
    }

    @Test func wireOrderSignedAttrsWithTamperedManifestFailsClosed() throws {
        // Stripping signedAttrs also strips the one attribute the library validates, so the fallback
        // re-does that comparison; without it a mutated manifest keeps a valid signature.
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
        // The fallback routes through the same config gating as the strict path.
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
        // The messageDigest is treated as *the* digest the signature commits to, so two of them -
        // even both correct - must fail closed rather than becoming a first-match guess.
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
        // Both signatures here are genuine; the envelope is refused because the trust claim is stated
        // for one signer. The library cannot help: the rebuild emits one SignerInfo, so it never sees
        // the second. Mutation-tested - relaxing the guard makes this verify.
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
