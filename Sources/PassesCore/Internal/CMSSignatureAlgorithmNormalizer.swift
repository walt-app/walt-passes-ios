import Foundation
import SwiftASN1

/// Rewrites each CMS `SignerInfo.signatureAlgorithm` from the bare `rsaEncryption` OID to the
/// `shaNNNWithRSAEncryption` OID implied by its `digestAlgorithm`, so swift-certificates 1.19.x
/// (which only knows the combined OIDs) can verify passes Apple PassKit signs this way; otherwise
/// a valid pass is misread as `.tampered(.manifestSignatureMismatch)` (walt-passes-ios#31).
/// Mirrors Android's BouncyCastle path.
///
/// Safe because the signature is over `signedAttrs`, not the `signatureAlgorithm` field, so the
/// rewrite cannot make a tampered pass verify; `digestAlgorithm` is left intact so swift-
/// certificates' `digestAlgorithmFor(signatureAlgorithm) == signer.digestAlgorithm` cross-check
/// still holds. RSA-only and digest-driven; every other shape returns byte-identical input.
func normalizeCMSSignatureAlgorithm(_ signatureBytes: [UInt8]) -> [UInt8] {
    do {
        let root = try DER.parse(signatureBytes)
        var serializer = DER.Serializer()
        let changed = try rewriteNode(root, into: &serializer)
        return changed ? serializer.serializedBytes : signatureBytes
    } catch {
        // Not parseable as DER, or an unexpected shape: leave it to the verifier unchanged.
        return signatureBytes
    }
}

private enum CMSOID {
    static let rsaEncryption: ASN1ObjectIdentifier = "1.2.840.113549.1.1.1"
    static let sha256: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.1"
    static let sha384: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.2"
    static let sha512: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.3"
    static let sha256WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.11"
    static let sha384WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.12"
    static let sha512WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.13"

    /// The `shaNNNWithRSAEncryption` OID implied by an RSA signer whose digest is `digest`.
    static func combinedRSA(forDigest digest: ASN1ObjectIdentifier) -> ASN1ObjectIdentifier? {
        switch digest {
        case sha256: return sha256WithRSA
        case sha384: return sha384WithRSA
        case sha512: return sha512WithRSA
        default: return nil
        }
    }
}

/// Re-serializes `node` into `serializer`, rewriting any `SignerInfo.signatureAlgorithm` that
/// carries bare `rsaEncryption`. Returns whether anything was rewritten anywhere in the subtree.
/// Untouched subtrees (certificates, signedAttrs, signatures) round-trip byte-for-byte *because
/// the input is canonical DER* (gated by `DER.parse`); the rebuild reproduces canonical DER, so
/// the bytes those signatures cover are unchanged.
private func rewriteNode(_ node: ASN1Node, into serializer: inout DER.Serializer) throws -> Bool {
    guard case .constructed(let collection) = node.content else {
        serializer.serialize(node)  // primitive: verbatim
        return false
    }

    let children = Array(collection)
    // A SignerInfo is the only place a bare-`rsaEncryption` AlgorithmIdentifier is immediately
    // followed by an OCTET STRING (the signature). An RSA SubjectPublicKeyInfo or a certificate
    // signatureAlgorithm is followed by a BIT STRING instead, so this never false-matches.
    let rewriteIndex = children.indices.first { index in
        index + 1 < children.count
            && children[index + 1].identifier == .octetString
            && isBareRSAAlgorithmIdentifier(children[index])
    }

    let replacement = rewriteIndex.flatMap { index in
        digestOID(amongSiblingsBefore: index, in: children)
            .flatMap(CMSOID.combinedRSA(forDigest:))
    }

    var changed = false
    try serializer.appendConstructedNode(identifier: node.identifier) { inner in
        for (index, child) in children.enumerated() {
            if index == rewriteIndex, let combined = replacement {
                try inner.appendConstructedNode(identifier: .sequence) { algorithmIdentifier in
                    try algorithmIdentifier.serialize(combined)
                    try algorithmIdentifier.serialize(ASN1Null())
                }
                changed = true
            } else if try rewriteNode(child, into: &inner) {
                changed = true
            }
        }
    }
    return changed
}

/// The leading OID of a constructed node - i.e. the `algorithm` field of an `AlgorithmIdentifier`
/// SEQUENCE. Returns nil for a primitive, an empty SEQUENCE, or a node whose first child is not an
/// OID (e.g. `issuerAndSerialNumber`, whose first child is a Name). `ASN1NodeCollection` is a
/// `Sequence`, not a `Collection`, so the first element is read through its iterator.
private func leadingOID(of node: ASN1Node) -> ASN1ObjectIdentifier? {
    guard case .constructed(let fields) = node.content else { return nil }
    var iterator = fields.makeIterator()
    guard let oidNode = iterator.next() else { return nil }
    return try? ASN1ObjectIdentifier(derEncoded: oidNode)
}

/// True if `node` is an `AlgorithmIdentifier` whose algorithm OID is bare `rsaEncryption` (the
/// combined `shaNNNWithRSAEncryption` OIDs are intentionally not matched).
private func isBareRSAAlgorithmIdentifier(_ node: ASN1Node) -> Bool {
    leadingOID(of: node) == CMSOID.rsaEncryption
}

/// The digest OID from the `SignerInfo`'s `digestAlgorithm` - the `AlgorithmIdentifier` among the
/// siblings before `index` whose OID is a known SHA digest.
private func digestOID(amongSiblingsBefore index: Int, in children: [ASN1Node]) -> ASN1ObjectIdentifier? {
    for sibling in children[..<index] {
        guard let oid = leadingOID(of: sibling) else { continue }
        if oid == CMSOID.sha256 || oid == CMSOID.sha384 || oid == CMSOID.sha512 {
            return oid
        }
    }
    return nil
}
