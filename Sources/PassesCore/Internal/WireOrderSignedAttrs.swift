import Crypto
import Foundation
import SwiftASN1

/// A CMS blob's `signedAttrs` as the issuer encoded them, paired with a copy of the blob that no
/// longer carries them. Passing the pair to `CMS.isValidSignature` as `dataBytes` / `signatureBytes`
/// makes it verify over the attribute bytes exactly as received.
internal struct WireOrderSignedAttrs {
    /// The `signedAttrs` SET re-tagged from `[0] IMPLICIT` and re-serialized in wire order: the bytes
    /// the issuer's key actually signed.
    let attributeBytes: [UInt8]
    let strippedSignatureBytes: [UInt8]
}

/// Prepares the wire-order fallback for a blob the strict path rejected, or returns nil to leave that
/// rejection standing. See `docs/CMS_WIRE_ORDER_SIGNEDATTRS.md` for the bug and the security argument.
///
/// The digest comparison below is load-bearing, not belt-and-braces: dropping `signedAttrs` also
/// drops the one signed attribute swift-certificates validates, so without re-doing it a tampered
/// manifest would keep a valid signature over its untouched attributes and verify.
///
/// Both halves of the binding come from ONE parse, so the digest checked is lifted out of the very
/// bytes returned for verification.
internal func prepareWireOrderFallback(
    signatureBytes: [UInt8],
    manifestBytes: [UInt8]
) -> WireOrderSignedAttrs? {
    guard let cms = CMSStructure(signatureBytes: signatureBytes),
        let attributes = cms.signedAttrsChildren,
        let digestOID = leadingOID(of: cms.digestAlgorithm),
        let messageDigest = soleMessageDigestValue(attributes),
        let actualDigest = digest(manifestBytes, using: digestOID),
        constantTimeEqual(messageDigest, actualDigest)
    else {
        return nil
    }
    return WireOrderSignedAttrs(
        attributeBytes: setTaggedEncoding(of: attributes),
        strippedSignatureBytes: cms.reserialized { signerInfo in
            for (index, field) in cms.signerInfoFields.enumerated()
            where index != CMSStructure.signedAttrsIndex {
                signerInfo.serialize(field)
            }
        }
    )
}

/// `children` re-tagged as a real SET, order preserved. `serializeSetOf` is deliberately not used: it
/// sorts, reproducing the very bytes the strict path already tried.
private func setTaggedEncoding(of children: [ASN1Node]) -> [UInt8] {
    var serializer = DER.Serializer()
    serializer.appendConstructedNode(identifier: .set) { attributes in
        for child in children {
            attributes.serialize(child)
        }
    }
    return serializer.serializedBytes
}

/// The one `messageDigest` attribute's one value, or nil if `attributes` holds a non-attribute
/// element, no `messageDigest`, more than one, or one carrying anything but a single OCTET STRING.
/// Requiring exactly one is what lets the caller treat the result as *the* digest the signature
/// commits to rather than a first-match guess.
private func soleMessageDigestValue(_ attributes: [ASN1Node]) -> [UInt8]? {
    var found: [UInt8]?
    for attribute in attributes {
        guard let children = constructedChildren(of: attribute), children.count == 2,
            let attrType = try? ASN1ObjectIdentifier(derEncoded: children[0]),
            let valueNodes = constructedChildren(of: children[1])
        else {
            return nil
        }
        guard attrType == CMSOID.messageDigest else { continue }
        guard found == nil, valueNodes.count == 1,
            let octets = try? ASN1OctetString(derEncoded: valueNodes[0])
        else {
            return nil
        }
        found = Array(octets.bytes)
    }
    return found
}

/// The digest of `bytes` under `oid`, or nil for a digest algorithm the kernel does not implement.
private func digest(_ bytes: [UInt8], using oid: ASN1ObjectIdentifier) -> [UInt8]? {
    switch oid {
    case CMSOID.sha1: return Array(Insecure.SHA1.hash(data: bytes))
    case CMSOID.sha256: return Array(SHA256.hash(data: bytes))
    case CMSOID.sha384: return Array(SHA384.hash(data: bytes))
    case CMSOID.sha512: return Array(SHA512.hash(data: bytes))
    default: return nil
    }
}

/// Length-then-content comparison with no early exit, mirroring Android's `MessageDigest.isEqual`.
private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}
