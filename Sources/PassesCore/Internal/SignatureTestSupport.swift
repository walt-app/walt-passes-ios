import Crypto
import Foundation
import SwiftASN1
import _CryptoExtras
@_spi(CMS) import X509

/// **Test-only support.** Shims P256 key/certificate generation and CMS signing through
/// PassesCore (which links `Crypto` transitively) so the test target does not need a direct
/// `swift-crypto` dependency. Not part of the public API; consumed only by `@testable import`
/// from `PassesCoreTests`. Mirrors the cert-construction pattern in swift-certificates'
/// `CMSTests.swift`.
internal enum SignatureTestSupport {
    /// Lowercase hex SHA-1 of `bytes`. Used by fixtures to build `manifest.json` hashes; routed
    /// through PassesCore so the test target need not link Crypto directly.
    static func sha1Hex(_ bytes: [UInt8]) -> String {
        Insecure.SHA1.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// A generated certificate authority or leaf, paired with the key needed to issue / sign.
    internal struct Issued {
        let certificate: Certificate
        let privateKey: Certificate.PrivateKey
    }

    /// Generates a self-signed CA root.
    static func makeRoot(commonName: String) throws -> Issued {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName(commonName) }
        return try makeSelfSigned(key: key, name: name, signatureAlgorithm: .ecdsaWithSHA256)
    }

    /// Generates a self-signed RSA CA root. RSA (not P256) because only an RSA signer can carry the
    /// bare-`rsaEncryption` / SHA-1 `SignerInfo` shape the normalizer exists to rewrite.
    static func makeRSARoot(commonName: String) throws -> Issued {
        let key = Certificate.PrivateKey(try _RSA.Signing.PrivateKey(keySize: .bits2048))
        let name = try DistinguishedName { CommonName(commonName) }
        return try makeSelfSigned(key: key, name: name, signatureAlgorithm: .sha256WithRSAEncryption)
    }

    /// Generates an RSA leaf issued by `issuer`. The certificate chain stays on SHA-256; only the
    /// CMS `SignerInfo` under test uses SHA-1, so the fixture isolates the behaviour being pinned.
    static func makeRSALeaf(commonName: String, issuer: Issued) throws -> Issued {
        let key = Certificate.PrivateKey(try _RSA.Signing.PrivateKey(keySize: .bits2048))
        let subject = try DistinguishedName { CommonName(commonName) }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 360),
            issuer: issuer.certificate.subject,
            subject: subject,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: issuer.privateKey
        )
        return Issued(certificate: cert, privateKey: key)
    }

    private static func makeSelfSigned(
        key: Certificate.PrivateKey,
        name: DistinguishedName,
        signatureAlgorithm: Certificate.SignatureAlgorithm
    ) throws -> Issued {
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 360),
            issuer: name,
            subject: name,
            signatureAlgorithm: signatureAlgorithm,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            },
            issuerPrivateKey: key
        )
        return Issued(certificate: cert, privateKey: key)
    }

    /// Generates an intermediate CA issued by `issuer`.
    static func makeIntermediate(commonName: String, issuer: Issued) throws -> Issued {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName { CommonName(commonName) }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 360),
            issuer: issuer.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            },
            issuerPrivateKey: issuer.privateKey
        )
        return Issued(certificate: cert, privateKey: key)
    }

    /// Generates a leaf certificate issued by `issuer`.
    static func makeLeaf(commonName: String, issuer: Issued) throws -> Issued {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName { CommonName(commonName) }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(60 * 60 * 24 * 360),
            issuer: issuer.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: issuer.privateKey
        )
        return Issued(certificate: cert, privateKey: key)
    }

    /// CMS-signs `manifestBytes` with `signer`, producing a detached PKCS#7 blob. Optionally
    /// includes intermediate certificates in the envelope.
    static func sign(
        manifestBytes: [UInt8],
        signer: Issued,
        intermediates: [Certificate] = []
    ) throws -> [UInt8] {
        try CMS.sign(
            manifestBytes,
            signatureAlgorithm: .ecdsaWithSHA256,
            additionalIntermediateCertificates: intermediates,
            certificate: signer.certificate,
            privateKey: signer.privateKey,
            detached: true
        )
    }

    /// CMS-signs `manifestBytes` with an RSA `signer` using SHA-1, then rewrites the resulting
    /// `SignerInfo.signatureAlgorithm` from the combined `sha1WithRSAEncryption` OID back to bare
    /// `rsaEncryption` - the wire shape Apple PassKit ships and the one reported in
    /// walt-passes-android#176. `CMS.sign` can only emit the combined OID, so the rewrite is the
    /// only way to synthesize the shape without a real Apple-signed SHA-1 pass.
    ///
    /// `signingTime` is passed so the envelope carries `signedAttrs`; without it `CMS.sign` emits a
    /// `SignerInfo` with no attributes at all, and the signature covers `manifestBytes` directly.
    static func signSHA1BareRSA(manifestBytes: [UInt8], signer: Issued) throws -> [UInt8] {
        let combined = try CMS.sign(
            manifestBytes,
            signatureAlgorithm: .sha1WithRSAEncryption,
            certificate: signer.certificate,
            privateKey: signer.privateKey,
            signingTime: Date(timeIntervalSince1970: 1_750_000_000),
            detached: true
        )
        return try rewriteToBareRSA(combined)
    }

    /// Inverse of `normalizeCMSSignatureAlgorithm`: rewrites the `SignerInfo.signatureAlgorithm`
    /// SEQUENCE - the `AlgorithmIdentifier` immediately followed by the signature OCTET STRING -
    /// to bare `rsaEncryption`, leaving `digestAlgorithm` and everything else untouched.
    private static func rewriteToBareRSA(_ signatureBytes: [UInt8]) throws -> [UInt8] {
        var serializer = DER.Serializer()
        let changed = try rewriteToBareRSANode(try DER.parse(signatureBytes), into: &serializer)
        guard changed else { throw TestSupportError.noSignerInfoAlgorithmToRewrite }
        return serializer.serializedBytes
    }

    private static func rewriteToBareRSANode(
        _ node: ASN1Node,
        into serializer: inout DER.Serializer
    ) throws -> Bool {
        guard case .constructed(let collection) = node.content else {
            serializer.serialize(node)
            return false
        }
        let children = Array(collection)
        let rewriteIndex = children.indices.first { index in
            index + 1 < children.count && children[index + 1].identifier == .octetString
                && leadingOID(of: children[index]) == CMSOID.sha1WithRSA
        }

        var changed = false
        try serializer.appendConstructedNode(identifier: node.identifier) { inner in
            for (index, child) in children.enumerated() {
                if index == rewriteIndex {
                    try inner.appendConstructedNode(identifier: .sequence) { algorithmIdentifier in
                        try algorithmIdentifier.serialize(CMSOID.rsaEncryption)
                        try algorithmIdentifier.serialize(ASN1Null())
                    }
                    changed = true
                } else if try rewriteToBareRSANode(child, into: &inner) {
                    changed = true
                }
            }
        }
        return changed
    }

    private static func leadingOID(of node: ASN1Node) -> ASN1ObjectIdentifier? {
        guard case .constructed(let fields) = node.content else { return nil }
        var iterator = fields.makeIterator()
        guard let oidNode = iterator.next() else { return nil }
        return try? ASN1ObjectIdentifier(derEncoded: oidNode)
    }

    internal enum TestSupportError: Error {
        case noSignerInfoAlgorithmToRewrite
    }

    /// Drives the test-only verifier seam so a synthesized chain can reach a stand-in root.
    static func verify(
        signatureBytes: [UInt8],
        manifestBytes: [UInt8],
        config: ParserConfig,
        trustAnchors: [Certificate],
        knownIntermediates: [Certificate]
    ) -> SignatureVerifyResult {
        verifySignatureAgainstAnchorsForTesting(
            signatureBytes: signatureBytes,
            manifestBytes: manifestBytes,
            config: config,
            trustAnchors: trustAnchors,
            knownIntermediates: knownIntermediates
        )
    }
}
