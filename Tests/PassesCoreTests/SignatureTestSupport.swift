import Crypto
import Foundation
import SwiftASN1
@_spi(CMS) import X509
import _CryptoExtras

@testable import PassesCore

/// Key/certificate generation and CMS signing for the signature-verifier tests, mirroring the
/// cert-construction pattern in swift-certificates' own `CMSTests.swift`. Lives in the test target so
/// no signing helper ships inside the verification kernel.
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
    /// bare-`rsaEncryption` `SignerInfo` shapes the normalizer exists to rewrite.
    static func makeRSARoot(commonName: String) throws -> Issued {
        let key = Certificate.PrivateKey(try _RSA.Signing.PrivateKey(keySize: .bits2048))
        let name = try DistinguishedName { CommonName(commonName) }
        return try makeSelfSigned(key: key, name: name, signatureAlgorithm: .sha256WithRSAEncryption)
    }

    /// Generates an RSA leaf issued by `issuer`. The certificate chain stays on SHA-256 with absent
    /// parameters, so only the CMS `SignerInfo` under test carries the shape being pinned.
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

    /// How a fixture encodes `digestAlgorithm` parameters at each of the two levels that carry one:
    /// the SignerInfo, and the SignedData `digestAlgorithms` SET. `SEQUENCE { oid, NULL }` and
    /// `SEQUENCE { oid }` are both legal, so all four combinations are legal, and nothing requires an
    /// issuer to use the same encoding at both levels.
    internal enum DigestParameters: CaseIterable {
        /// NULL at both levels - what `CMS.sign` and the real SHA-1 pkpasses emit for SHA-1, and
        /// what Tickster emits for SHA-256.
        case explicitNull
        /// Absent at both levels - what `CMS.sign` and Apple PassKit emit for SHA-256.
        case absent
        /// Absent in the SignerInfo, NULL in the SignedData SET.
        case absentInSignerInfoOnly
        /// NULL in the SignerInfo, absent in the SignedData SET.
        case absentInDeclaredOnly

        var signerInfoAbsent: Bool {
            self == .absent || self == .absentInSignerInfoOnly
        }

        var declaredAbsent: Bool {
            self == .absent || self == .absentInDeclaredOnly
        }
    }

    /// CMS-signs `manifestBytes` with an RSA `signer` using SHA-1, then rewrites
    /// `SignerInfo.signatureAlgorithm` from the combined OID back to bare `rsaEncryption` - the wire
    /// shape Apple PassKit ships - and re-encodes the digest parameters per `digestParameters`.
    /// `CMS.sign` emits only the combined OID, so the rewrite is the only way to synthesize the shape
    /// without a real Apple-signed SHA-1 pass.
    static func signSHA1BareRSA(
        manifestBytes: [UInt8],
        signer: Issued,
        digestParameters: DigestParameters = .explicitNull
    ) throws -> [UInt8] {
        try signBareRSA(
            manifestBytes: manifestBytes,
            signer: signer,
            signatureAlgorithm: .sha1WithRSAEncryption,
            digest: CMSOID.sha1,
            digestParameters: digestParameters
        )
    }

    /// The SHA-256 counterpart. `CMS.sign` emits absent parameters here, so `.explicitNull` is the
    /// Tickster shape that has to be synthesized.
    static func signSHA256BareRSA(
        manifestBytes: [UInt8],
        signer: Issued,
        digestParameters: DigestParameters = .absent
    ) throws -> [UInt8] {
        try signBareRSA(
            manifestBytes: manifestBytes,
            signer: signer,
            signatureAlgorithm: .sha256WithRSAEncryption,
            digest: CMSOID.sha256,
            digestParameters: digestParameters
        )
    }

    /// `signingTime` is passed so the envelope carries `signedAttrs`; without it `CMS.sign` emits no
    /// attributes and the signature covers `manifestBytes` directly. Both digest identifiers are
    /// re-emitted structurally, so a fixture can carry a different encoding at each level.
    private static func signBareRSA(
        manifestBytes: [UInt8],
        signer: Issued,
        signatureAlgorithm: Certificate.SignatureAlgorithm,
        digest: ASN1ObjectIdentifier,
        digestParameters: DigestParameters
    ) throws -> [UInt8] {
        let combined = try CMS.sign(
            manifestBytes,
            signatureAlgorithm: signatureAlgorithm,
            certificate: signer.certificate,
            privateKey: signer.privateKey,
            signingTime: Date(timeIntervalSince1970: 1_750_000_000),
            detached: true
        )
        let cms = try require(CMSStructure(signatureBytes: combined))
        guard let emitted = cms.signatureAlgorithm,
            leadingOID(of: emitted) == CMSOID.combinedRSA(forDigest: digest)
        else {
            throw TestSupportError.noSignerInfoAlgorithmToRewrite
        }
        return try cms.reserialized(
            digestAlgorithms: { set in
                try serializeAlgorithmIdentifier(
                    digest, nullParameters: !digestParameters.declaredAbsent, into: &set)
            },
            signerInfo: { signerInfo in
                for (index, field) in cms.signerInfoFields.enumerated() {
                    switch index {
                    case CMSStructure.digestAlgorithmIndex:
                        try serializeAlgorithmIdentifier(
                            digest, nullParameters: !digestParameters.signerInfoAbsent,
                            into: &signerInfo)
                    case cms.signatureAlgorithmIndex:
                        try serializeAlgorithmIdentifier(CMSOID.rsaEncryption, into: &signerInfo)
                    default:
                        signerInfo.serialize(field)
                    }
                }
            }
        )
    }

    /// How a wire-order fixture's `signedAttrs` SET should deviate from sorted DER order.
    internal enum SignedAttrsShape {
        /// Elements reversed out of DER order and signed in that order - the real-world bug.
        case reversed
        /// Reversed, and with the `messageDigest` attribute duplicated, so the fallback cannot treat
        /// any one of them as *the* digest the signature commits to.
        case reversedWithDuplicateMessageDigest
        /// Reversed, with the sole SignerInfo duplicated so the envelope carries two signers. Both
        /// signatures are genuine; the envelope must still be refused.
        case reversedWithTwoSigners
    }

    /// CMS-signs `manifestBytes` the way an issuer whose tooling emits `signedAttrs` in wire order
    /// does: `CMS.sign` is used to obtain a well-formed envelope, then its `signedAttrs` elements are
    /// re-ordered per `shape` and the SET-tagged encoding of THAT order is re-signed with the
    /// signer's key. The result is cryptographically sound yet rejected by stock swift-certificates,
    /// which is the reported bug.
    static func signWithWireOrderSignedAttrs(
        manifestBytes: [UInt8],
        signer: Issued,
        shape: SignedAttrsShape = .reversed
    ) throws -> [UInt8] {
        let sorted = try CMS.sign(
            manifestBytes,
            signatureAlgorithm: .ecdsaWithSHA256,
            certificate: signer.certificate,
            privateKey: signer.privateKey,
            signingTime: Date(timeIntervalSince1970: 1_750_000_000),
            detached: true
        )
        return try reorderSignedAttrs(sorted, signer: signer, shape: shape)
    }

    private static func reorderSignedAttrs(
        _ signatureBytes: [UInt8],
        signer: Issued,
        shape: SignedAttrsShape
    ) throws -> [UInt8] {
        let contentInfo = try children(of: try DER.parse(signatureBytes))
        let explicitContent = contentInfo[1]
        let signedData = try children(of: try children(of: explicitContent)[0])
        let signerInfos = try children(of: try require(signedData.last))
        let signerInfo = try children(of: signerInfos[0])

        var attributes = Array(try children(of: signerInfo[CMSStructure.signedAttrsIndex]).reversed())
        if shape == .reversedWithDuplicateMessageDigest {
            attributes.append(try require(attributes.first { leadingOID(of: $0) == CMSOID.messageDigest }))
        }

        // Sign the SET-tagged encoding of the re-ordered elements: the signature must cover the
        // bytes in wire order, otherwise the fixture is just a corrupt pass.
        var attributeCoder = DER.Serializer()
        attributeCoder.appendConstructedNode(identifier: .set) { set in
            for attribute in attributes { set.serialize(attribute) }
        }
        let signature = try signatureNode(over: attributeCoder.serializedBytes, signer: signer)

        let signerCount = shape == .reversedWithTwoSigners ? 2 : 1
        var serializer = DER.Serializer()
        serializer.appendConstructedNode(identifier: .sequence) { outer in
            outer.serialize(contentInfo[0])
            outer.appendConstructedNode(identifier: explicitContent.identifier) { explicit in
                explicit.appendConstructedNode(identifier: .sequence) { data in
                    for field in signedData.dropLast() { data.serialize(field) }
                    data.appendConstructedNode(identifier: .set) { signerInfos in
                        for _ in 0..<signerCount {
                            signerInfos.appendConstructedNode(identifier: .sequence) { info in
                                for (index, field) in signerInfo.enumerated() {
                                    switch index {
                                    case CMSStructure.signedAttrsIndex:
                                        info.appendConstructedNode(identifier: field.identifier) { attrs in
                                            for attribute in attributes { attrs.serialize(attribute) }
                                        }
                                    case signerInfo.count - 1:
                                        info.serialize(signature)
                                    default:
                                        info.serialize(field)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return serializer.serializedBytes
    }

    /// The signature OCTET STRING covering `bytes` under `signer`'s key, lifted out of a throwaway
    /// `CMS.sign` envelope. Going through `CMS.sign` avoids needing `ASN1OctetString`'s internal
    /// initializer from `Certificate.Signature`; without a `signingTime` the envelope carries no
    /// `signedAttrs`, so its signature covers `bytes` directly and its final SignerInfo field is
    /// exactly the node needed.
    private static func signatureNode(over bytes: [UInt8], signer: Issued) throws -> ASN1Node {
        let envelope = try CMS.sign(
            bytes,
            signatureAlgorithm: .ecdsaWithSHA256,
            certificate: signer.certificate,
            privateKey: signer.privateKey,
            detached: true
        )
        let contentInfo = try children(of: try DER.parse(envelope))
        let signedData = try children(of: try children(of: contentInfo[1])[0])
        let signerInfo = try children(of: try children(of: try require(signedData.last))[0])
        guard let signature = signerInfo.last, signature.identifier == .octetString else {
            throw TestSupportError.unexpectedShape
        }
        return signature
    }

    private static func children(of node: ASN1Node) throws -> [ASN1Node] {
        guard let children = constructedChildren(of: node) else {
            throw TestSupportError.unexpectedShape
        }
        return children
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw TestSupportError.unexpectedShape }
        return value
    }

    internal enum TestSupportError: Error {
        case noSignerInfoAlgorithmToRewrite
        case unexpectedShape
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
