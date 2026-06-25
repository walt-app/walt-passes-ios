import Foundation
import SwiftASN1

/// Normalizes a detached PKCS#7 / CMS blob so swift-certificates can verify passes whose
/// `SignerInfo.signatureAlgorithm` carries the bare `rsaEncryption` OID (`1.2.840.113549.1.1.1`,
/// parameters absent) with the hash conveyed separately in `digestAlgorithm`. This is exactly
/// what Apple PassKit emits; swift-certificates 1.19.x only recognizes the combined
/// `shaNNNWithRSAEncryption` OIDs, so it throws while resolving the algorithm and Walt
/// misclassifies a valid pass as `.tampered(.manifestSignatureMismatch)` (walt-passes-ios#31).
///
/// The fix replicates BouncyCastle's behavior (Android): rewrite each `SignerInfo`'s bare
/// `rsaEncryption` `signatureAlgorithm` to the `shaNNNWithRSAEncryption` OID implied by that
/// signer's `digestAlgorithm`, then hand the rewritten DER to `CMS.isValidSignature`. The
/// signature is computed over `signedAttrs`, not over the `signatureAlgorithm` field, so the
/// rewrite does not invalidate it; `digestAlgorithm` / `digestAlgorithms` are left untouched so
/// swift-certificates' `digestAlgorithmFor(signatureAlgorithm) == signer.digestAlgorithm`
/// cross-check still holds.
///
/// **Scope.** RSA-only and digest-driven. ECDSA / Ed25519 signers and the combined RSA OIDs are
/// left alone. Anything that does not parse as the expected structure, or whose digest is not one
/// of SHA-256/384/512, is returned unchanged so the verifier classifies it exactly as before -
/// this can only ever turn a previously-failing bare-`rsaEncryption` pass into a verifiable one.
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
/// Constructed nodes that contain no rewrite are still rebuilt structurally; for DER the rebuild
/// is byte-for-byte canonical, so untouched subtrees (certificates, signedAttrs, signatures)
/// round-trip exactly.
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

/// True if `node` is an `AlgorithmIdentifier` SEQUENCE whose algorithm OID is bare
/// `rsaEncryption` (the combined `shaNNNWithRSAEncryption` OIDs are intentionally not matched).
private func isBareRSAAlgorithmIdentifier(_ node: ASN1Node) -> Bool {
    guard case .constructed(let fields) = node.content, let oidNode = fields.first(where: { _ in true }),
        let oid = try? ASN1ObjectIdentifier(derEncoded: oidNode)
    else {
        return false
    }
    return oid == CMSOID.rsaEncryption
}

/// The digest OID from the `SignerInfo`'s `digestAlgorithm` - the AlgorithmIdentifier SEQUENCE
/// among the siblings before `index` whose OID is a known SHA digest. (The sibling list may also
/// hold `issuerAndSerialNumber`, which is a SEQUENCE but whose first element is a Name, not an
/// OID, so it is skipped.)
private func digestOID(amongSiblingsBefore index: Int, in children: [ASN1Node]) -> ASN1ObjectIdentifier? {
    for sibling in children[..<index] {
        guard case .constructed(let fields) = sibling.content, let oidNode = fields.first(where: { _ in true }),
            let oid = try? ASN1ObjectIdentifier(derEncoded: oidNode)
        else {
            continue
        }
        if oid == CMSOID.sha256 || oid == CMSOID.sha384 || oid == CMSOID.sha512 {
            return oid
        }
    }
    return nil
}
