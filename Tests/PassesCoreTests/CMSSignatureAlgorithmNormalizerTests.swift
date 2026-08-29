import Foundation
import SwiftASN1
import Testing

@testable import PassesCore

/// The `normalizeCMSSignatureAlgorithm` pre-pass, driven through the test-only verifier seam with
/// synthesized signers. The real Apple-signed fixtures run in `SignatureVerifierTests`.
@Suite("CMSSignatureAlgorithmNormalizer")
struct CMSSignatureAlgorithmNormalizerTests {
    typealias Digest = SignatureTestSupport.RSADigest
    typealias Shape = SignatureTestSupport.DigestParameters

    private let manifest = [UInt8]("{\"pass.json\":\"abc\"}".utf8)
    private let tamperedManifest = [UInt8]("{\"pass.json\":\"DIFFERENT\"}".utf8)

    @Test(arguments: Digest.allCases, Shape.allCases)
    func bareRSASignerIsAppleVerified(digest: Digest, shape: Shape) throws {
        // Bare `rsaEncryption` with every legal digest parameter encoding. The library derives NULL
        // for SHA-1 and absent for SHA-2 and checks the two levels separately, so each digest has
        // three shapes that read Tampered without the parameter rewrite.
        let (root, leaf) = try rsaChain()
        let signature = try SignatureTestSupport.signBareRSA(
            manifestBytes: manifest, signer: leaf, digest: digest, digestParameters: shape)
        #expect(verify(signature, manifest: manifest, root: root) == .ok(.appleVerified))
    }

    @Test(arguments: Digest.allCases)
    func bareRSAWithTamperedManifestStillFails(digest: Digest) throws {
        // Neither rewrite may let a mutated manifest verify. A mixed shape, so the parameter rewrite
        // runs for every digest.
        let (root, leaf) = try rsaChain()
        let signature = try SignatureTestSupport.signBareRSA(
            manifestBytes: manifest, signer: leaf, digest: digest,
            digestParameters: .absentInSignerInfoOnly)
        #expect(
            verify(signature, manifest: tamperedManifest, root: root)
                == .failed(.manifestSignatureMismatch))
    }

    @Test(arguments: Digest.allCases)
    func fixtureShapesDifferOnTheWire(digest: Digest) throws {
        // Anti-vacuity: the four parameter encodings must be distinct blobs, or the tests above
        // could be re-running one shape.
        let (_, leaf) = try rsaChain()
        let encodings = try Shape.allCases.map { shape in
            try SignatureTestSupport.signBareRSA(
                manifestBytes: manifest, signer: leaf, digest: digest, digestParameters: shape)
        }
        #expect(Set(encodings).count == Shape.allCases.count)
    }

    @Test(arguments: Digest.allCases)
    func normalizerCanonicalizesDigestParametersAtBothLevels(digest: Digest) throws {
        // For one signer all four shapes normalize to identical bytes. RSA PKCS#1 v1.5 is
        // deterministic and the signingTime fixed, so only the identifiers can differ.
        let (_, leaf) = try rsaChain()
        let normalized = try Shape.allCases.map { shape in
            normalizeCMSSignatureAlgorithm(
                try SignatureTestSupport.signBareRSA(
                    manifestBytes: manifest, signer: leaf, digest: digest, digestParameters: shape))
        }
        #expect(Set(normalized).count == 1)
    }

    @Test(arguments: Digest.allCases)
    func normalizerRewritesBareRSAToCombinedOID(digest: Digest) throws {
        // The fixture really carries bare `rsaEncryption`, and the normalizer replaces it with the
        // combined OID the library knows.
        let (_, leaf) = try rsaChain()
        let signature = try SignatureTestSupport.signBareRSA(
            manifestBytes: manifest, signer: leaf, digest: digest, digestParameters: .absent)
        #expect(signatureAlgorithmOID(of: signature) == CMSOID.rsaEncryption)
        #expect(
            signatureAlgorithmOID(of: normalizeCMSSignatureAlgorithm(signature))
                == CMSOID.combinedRSA(forDigest: digest.oid))
    }

    @Test(arguments: Shape.allCases)
    func ecdsaSignerIsAppleVerified(shape: Shape) throws {
        // The parameter rewrite is not tied to RSA: the library derives absent parameters for
        // `ecdsaWithSHA256` too, so an ECDSA signer with NULL at either level needs the same strip.
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signECDSA(
            manifestBytes: manifest, signer: leaf, digestParameters: shape)
        #expect(verify(signature, manifest: manifest, root: root) == .ok(.appleVerified))
    }

    @Test func ecdsaWithNullDigestParametersAndTamperedManifestFails() throws {
        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let signature = try SignatureTestSupport.signECDSA(
            manifestBytes: manifest, signer: leaf, digestParameters: .explicitNull)
        #expect(
            verify(signature, manifest: tamperedManifest, root: root)
                == .failed(.manifestSignatureMismatch))
    }

    @Test func normalizerLeavesUnrewritableBlobsByteIdentical() throws {
        // Anything needing neither rewrite round-trips verbatim: non-DER garbage, and an ECDSA blob
        // in the shape `CMS.sign` emits. The real bare-RSA fixture IS rewritten, so the round-trips
        // above are meaningful.
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02]
        #expect(normalizeCMSSignatureAlgorithm(garbage) == garbage)

        let root = try SignatureTestSupport.makeRoot(commonName: "Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Leaf", issuer: root)
        let ecdsa = try SignatureTestSupport.signECDSA(
            manifestBytes: manifest, signer: leaf, digestParameters: .absent)
        #expect(normalizeCMSSignatureAlgorithm(ecdsa) == ecdsa)

        let fixture = try AppleSignedFixture.load()
        #expect(normalizeCMSSignatureAlgorithm(fixture.signature) != fixture.signature)
    }

    private func rsaChain() throws -> (root: SignatureTestSupport.Issued, leaf: SignatureTestSupport.Issued) {
        let root = try SignatureTestSupport.makeRSARoot(commonName: "RSA Root")
        return (root, try SignatureTestSupport.makeRSALeaf(commonName: "RSA Leaf", issuer: root))
    }

    private func verify(
        _ signature: [UInt8], manifest: [UInt8], root: SignatureTestSupport.Issued
    ) -> SignatureVerifyResult {
        SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifest,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
    }

    private func signatureAlgorithmOID(of blob: [UInt8]) -> ASN1ObjectIdentifier? {
        CMSStructure(signatureBytes: blob)?.signatureAlgorithm.flatMap(leadingOID)
    }
}
