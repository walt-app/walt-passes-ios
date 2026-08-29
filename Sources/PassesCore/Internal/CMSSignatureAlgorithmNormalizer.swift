import Foundation
import SwiftASN1

/// Rewrites a CMS `SignerInfo`'s algorithm identifiers into the encodings swift-certificates 1.19.x
/// accepts, so a valid Apple pass is not misread as `.tampered`. Byte-identical output for any shape
/// needing neither rewrite.
///
/// Two rewrites, both driven by `digestAlgorithm`:
///  - `signatureAlgorithm` bare `rsaEncryption` -> the implied `shaNNNWithRSAEncryption`. Apple
///    PassKit ships the bare OID, which the library does not know.
///  - `digestAlgorithm` parameters -> the encoding the library derives for that digest (NULL for
///    SHA-1, absent for SHA-2), at each of the two levels carrying one. RFC 5754 s2 allows either on
///    the wire, but the library compares with `==`. Tickster signs SHA-256 with NULL.
///
/// Neither field is covered by the signature - that is over `signedAttrs` - so no rewrite can make a
/// tampered pass verify. Both target the sole SignerInfo structurally, so certificates, whose own
/// signatures DO cover their algorithm identifiers, are never touched.
func normalizeCMSSignatureAlgorithm(_ signatureBytes: [UInt8]) -> [UInt8] {
    guard let cms = CMSStructure(signatureBytes: signatureBytes),
        let digestOID = leadingOID(of: cms.digestAlgorithm)
    else {
        return signatureBytes
    }

    let combinedRSA = combinedRSARewrite(cms, digestOID: digestOID)
    let parameters = digestParameterRewrite(cms, digestOID: digestOID)
    guard combinedRSA != nil || parameters.isNeeded else { return signatureBytes }

    let normalized = try? cms.reserialized(
        digestAlgorithms: parameters.declared
            ? {
                try serializeAlgorithmIdentifier(
                    digestOID, nullParameters: parameters.nullParameters, into: &$0)
            }
            : nil
    ) { signerInfo in
        for (index, field) in cms.signerInfoFields.enumerated() {
            if index == CMSStructure.digestAlgorithmIndex, parameters.signerInfo {
                try serializeAlgorithmIdentifier(
                    digestOID, nullParameters: parameters.nullParameters, into: &signerInfo)
            } else if index == cms.signatureAlgorithmIndex, let combinedRSA {
                try serializeAlgorithmIdentifier(combinedRSA, into: &signerInfo)
            } else {
                signerInfo.serialize(field)
            }
        }
    }
    return normalized ?? signatureBytes
}

/// The combined RSA OID to substitute for a bare `rsaEncryption` `signatureAlgorithm`, or nil if the
/// signer does not have that shape.
private func combinedRSARewrite(
    _ cms: CMSStructure,
    digestOID: ASN1ObjectIdentifier
) -> ASN1ObjectIdentifier? {
    guard let signatureAlgorithm = cms.signatureAlgorithm,
        leadingOID(of: signatureAlgorithm) == CMSOID.rsaEncryption
    else {
        return nil
    }
    return CMSOID.combinedRSA(forDigest: digestOID)
}

/// Which of the two levels carrying a `digestAlgorithm` need re-encoding, and to what. The levels
/// are independent: all four combinations of absent / NULL are legal DER.
private struct DigestParameterRewrite {
    /// The encoding the library derives for this digest: NULL for SHA-1, absent for SHA-2.
    let nullParameters: Bool
    let signerInfo: Bool
    let declared: Bool

    static let none = DigestParameterRewrite(nullParameters: false, signerInfo: false, declared: false)
    var isNeeded: Bool { signerInfo || declared }
}

/// The library checks both levels separately, so both must end up in the derived encoding. Only a
/// single-member SET for the same digest is rewritten, so it can be kept in step without reordering.
/// See docs/CMS_WIRE_ORDER_SIGNEDATTRS.md, "The algorithm pre-pass".
private func digestParameterRewrite(
    _ cms: CMSStructure,
    digestOID: ASN1ObjectIdentifier
) -> DigestParameterRewrite {
    guard CMSOID.knownDigests.contains(digestOID),
        let declared = cms.declaredDigestAlgorithms, declared.count == 1,
        leadingOID(of: declared[0]) == digestOID
    else {
        return .none
    }
    let nullParameters = digestOID == CMSOID.sha1
    return DigestParameterRewrite(
        nullParameters: nullParameters,
        signerInfo: parametersDiffer(in: cms.digestAlgorithm, fromNull: nullParameters),
        declared: parametersDiffer(in: declared[0], fromNull: nullParameters)
    )
}

/// True when the identifier carries the opposite encoding from the one wanted. Only
/// `SEQUENCE { oid }` and `SEQUENCE { oid, NULL }` qualify; any other parameters are left alone.
private func parametersDiffer(in algorithmIdentifier: ASN1Node, fromNull wantsNull: Bool) -> Bool {
    guard let fields = constructedChildren(of: algorithmIdentifier) else { return false }
    switch fields.count {
    case 1: return wantsNull
    case 2: return !wantsNull && fields[1].identifier == .null
    default: return false
    }
}
