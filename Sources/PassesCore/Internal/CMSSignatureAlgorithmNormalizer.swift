import Foundation
import SwiftASN1

/// Rewrites a CMS `SignerInfo`'s algorithm identifiers into the encodings swift-certificates 1.19.x
/// accepts, so a valid Apple pass is not misread as `.tampered`. Byte-identical output for any shape
/// needing neither rewrite.
///
/// Two rewrites, both driven by `digestAlgorithm`:
///  - `signatureAlgorithm` bare `rsaEncryption` -> the implied `shaNNNWithRSAEncryption`. Apple
///    PassKit ships the bare OID, which the library does not know.
///  - a SHA-1 `digestAlgorithm` with absent parameters -> explicit NULL, at each of the two levels
///    that carry one. The library derives the expected digest identifier from the signature algorithm
///    and compares with `==`; its SHA-1 case is the only one carrying NULL rather than absent
///    parameters, so an absent-parameters SHA-1 signer fails a comparison other digests pass.
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
    let sha1Parameters = sha1ParameterRewrite(cms, digestOID: digestOID)
    guard combinedRSA != nil || sha1Parameters.isNeeded else { return signatureBytes }

    let normalized = try? cms.reserialized(
        digestAlgorithms: sha1Parameters.declared
            ? { try serializeAlgorithmIdentifier(CMSOID.sha1, into: &$0) }
            : nil
    ) { signerInfo in
        for (index, field) in cms.signerInfoFields.enumerated() {
            if index == CMSStructure.digestAlgorithmIndex, sha1Parameters.signerInfo {
                try serializeAlgorithmIdentifier(CMSOID.sha1, into: &signerInfo)
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

/// Which of the two levels carrying a SHA-1 `digestAlgorithm` need NULL parameters added. The levels
/// are independent: nothing stops an issuer encoding `SEQUENCE { sha1 }` at one and
/// `SEQUENCE { sha1, NULL }` at the other, and all four combinations are legal DER.
private struct SHA1ParameterRewrite {
    let signerInfo: Bool
    let declared: Bool

    static let none = SHA1ParameterRewrite(signerInfo: false, declared: false)
    var isNeeded: Bool { signerInfo || declared }
}

/// Both levels must end up carrying NULL, because the library checks them separately: it compares the
/// SignerInfo's `digestAlgorithm` against the `.sha1` identifier it derives from the signature
/// algorithm, and it also requires the SignedData `digestAlgorithms` SET to contain that identifier.
/// Fixing one level alone just trades one false `.tampered` for another.
///
/// So no rewrite is attempted unless the SET is a single SHA-1 identifier this can keep in step. The
/// library parses that SET with `DER.set`, which requires lexicographic order, so re-encoding one
/// member of a larger set risks breaking the ordering; and a larger set cannot be guaranteed to hold
/// the rewritten identifier the `contains` check will look for.
private func sha1ParameterRewrite(
    _ cms: CMSStructure,
    digestOID: ASN1ObjectIdentifier
) -> SHA1ParameterRewrite {
    guard digestOID == CMSOID.sha1,
        let declared = cms.declaredDigestAlgorithms, declared.count == 1,
        leadingOID(of: declared[0]) == CMSOID.sha1
    else {
        return .none
    }
    return SHA1ParameterRewrite(
        signerInfo: parametersAreAbsent(cms.digestAlgorithm),
        declared: parametersAreAbsent(declared[0])
    )
}

private func parametersAreAbsent(_ algorithmIdentifier: ASN1Node) -> Bool {
    constructedChildren(of: algorithmIdentifier)?.count == 1
}
