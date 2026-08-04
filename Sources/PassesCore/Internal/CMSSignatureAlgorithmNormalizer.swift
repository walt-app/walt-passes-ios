import Foundation
import SwiftASN1

/// Rewrites a CMS `SignerInfo`'s algorithm identifiers into the encodings swift-certificates 1.19.x
/// accepts, so a valid Apple pass is not misread as `.tampered`. Byte-identical output for any shape
/// needing neither rewrite.
///
/// Two rewrites, both driven by `digestAlgorithm`:
///  - `signatureAlgorithm` bare `rsaEncryption` -> the implied `shaNNNWithRSAEncryption`. Apple
///    PassKit ships the bare OID, which the library does not know.
///  - a SHA-1 `digestAlgorithm` with absent parameters -> explicit NULL. The library derives the
///    expected digest identifier from the signature algorithm and compares with `==`; its SHA-1 case
///    is the only one carrying NULL rather than absent parameters, so an absent-parameters SHA-1
///    signer fails a comparison SHA-256/384/512 signers pass.
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
    let needsDigestNULL = needsSHA1NULLParameters(cms, digestOID: digestOID)
    guard combinedRSA != nil || needsDigestNULL else { return signatureBytes }

    return cms.reserialized(
        digestAlgorithms: needsDigestNULL
            ? { serializeAlgorithmIdentifier(CMSOID.sha1, into: &$0) }
            : nil
    ) { signerInfo in
        for (index, field) in cms.signerInfoFields.enumerated() {
            if index == CMSStructure.digestAlgorithmIndex, needsDigestNULL {
                serializeAlgorithmIdentifier(CMSOID.sha1, into: &signerInfo)
            } else if index == cms.signatureAlgorithmIndex, let combinedRSA {
                serializeAlgorithmIdentifier(combinedRSA, into: &signerInfo)
            } else {
                signerInfo.serialize(field)
            }
        }
    }
}

/// The combined RSA OID to substitute for a bare `rsaEncryption` `signatureAlgorithm`, or nil if the
/// signer does not have that shape.
private func combinedRSARewrite(
    _ cms: CMSStructure,
    digestOID: ASN1ObjectIdentifier
) -> ASN1ObjectIdentifier? {
    guard leadingOID(of: cms.signatureAlgorithm) == CMSOID.rsaEncryption else { return nil }
    return CMSOID.combinedRSA(forDigest: digestOID)
}

/// Whether this is a SHA-1 signer whose `digestAlgorithm` omits the NULL parameters the library
/// expects. Restricted to a single-element `digestAlgorithms` SET: the library parses that SET with
/// `DER.set`, which requires lexicographic order, so re-encoding one member of a larger set could
/// break the ordering instead.
private func needsSHA1NULLParameters(
    _ cms: CMSStructure,
    digestOID: ASN1ObjectIdentifier
) -> Bool {
    guard digestOID == CMSOID.sha1, parametersAreAbsent(cms.digestAlgorithm),
        let declared = cms.declaredDigestAlgorithms, declared.count == 1,
        leadingOID(of: declared[0]) == CMSOID.sha1, parametersAreAbsent(declared[0])
    else {
        return false
    }
    return true
}

private func parametersAreAbsent(_ algorithmIdentifier: ASN1Node) -> Bool {
    constructedChildren(of: algorithmIdentifier)?.count == 1
}
