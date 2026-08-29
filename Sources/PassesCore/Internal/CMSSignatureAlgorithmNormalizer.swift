import Foundation
import SwiftASN1

/// Rewrites a CMS `SignerInfo`'s algorithm identifiers into the encodings swift-certificates 1.19.x
/// accepts, so a valid Apple pass is not misread as `.tampered`. Byte-identical output for any shape
/// needing neither rewrite.
///
/// Two rewrites, both driven by `digestAlgorithm`:
///  - `signatureAlgorithm` bare `rsaEncryption` -> the implied `shaNNNWithRSAEncryption`. Apple
///    PassKit ships the bare OID, which the library does not know.
///  - `digestAlgorithm` parameters -> the one encoding the library derives for that digest: explicit
///    NULL for SHA-1, absent for SHA-2. RFC 5754 s2 lets a sender emit either and requires a
///    receiver to accept both, but the library derives a single identifier from the signature
///    algorithm and compares with `==`, so the other encoding fails. Applied at each of the two
///    levels that carry a digest identifier. Seen in both directions: Tickster signs SHA-256 with
///    NULL.
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

/// Which of the two levels carrying a `digestAlgorithm` need their parameters re-encoded, and to
/// what. The levels are independent: nothing stops an issuer encoding `SEQUENCE { oid }` at one and
/// `SEQUENCE { oid, NULL }` at the other, and all four combinations are legal DER.
private struct DigestParameterRewrite {
    /// The encoding the library derives for this digest: NULL for SHA-1, absent for SHA-2.
    let nullParameters: Bool
    let signerInfo: Bool
    let declared: Bool

    static let none = DigestParameterRewrite(nullParameters: false, signerInfo: false, declared: false)
    var isNeeded: Bool { signerInfo || declared }
}

/// Both levels must end up in the derived encoding, because the library checks them separately: it
/// compares the SignerInfo's `digestAlgorithm` against the identifier it derives from the signature
/// algorithm, and it also requires the SignedData `digestAlgorithms` SET to contain that identifier.
/// Fixing one level alone just trades one false `.tampered` for another.
///
/// So no rewrite is attempted unless the SET is a single identifier for the same digest this can
/// keep in step. The library parses that SET with `DER.set`, which requires lexicographic order, so
/// re-encoding one member of a larger set risks breaking the ordering; and a larger set cannot be
/// guaranteed to hold the rewritten identifier the `contains` check will look for.
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
