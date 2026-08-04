import Crypto
import Foundation
import SwiftASN1

/// The `signedAttrs` of a CMS blob as the issuer encoded them, paired with a copy of the blob that
/// no longer carries them. Feeding the pair to `CMS.isValidSignature` as `dataBytes` /
/// `signatureBytes` makes swift-certificates verify the signature over the attribute bytes exactly
/// as received, which is what the wire-order fallback needs. See `prepareWireOrderFallback`.
internal struct WireOrderSignedAttrs {
    /// The `signedAttrs` SET, re-tagged from `[0] IMPLICIT` back to a real SET and re-serialized
    /// with its elements in the order they appear on the wire. These are the bytes the issuer's
    /// private key actually signed.
    let attributeBytes: [UInt8]

    /// The CMS blob with the sole SignerInfo's `[0] signedAttrs` element removed, and nothing else
    /// changed.
    let strippedSignatureBytes: [UInt8]
}

/// Prepares the wire-order fallback for a CMS blob the strict path rejected, or returns `nil` to
/// leave that rejection standing.
///
/// **The bug.** RFC 5652 says the signature covers the DER encoding of `SignedAttributes`, and DER
/// requires a SET's elements sorted by their encodings. Some issuers' tooling signs the elements in
/// the order it emitted them instead (observed on Android: `contentType`, `messageDigest`,
/// `signingTime`, whose encodings 0x18 / 0x23 / 0x1c are not ascending). swift-asn1 refuses such a
/// SET outright - `DER.lazySet` throws "SET OF fields are not lexicographically ordered", and
/// `CMSSignerInfo` deliberately routes `signedAttrs` through `DER.set` - so the blob fails at parse
/// and swift-certificates reports a structurally invalid CMS block. Apple Wallet, Google Wallet,
/// FossWallet and OpenSSL all verify over the bytes as received and accept these passes, so only
/// Walt called them forged. Android hit the same bug through a different arm (BouncyCastle parsed
/// the SET, then re-encoded it sorted before hashing) and fixed it in `wpass-x70` / 824abc5.
///
/// **How the fallback avoids re-implementing the trust path.** swift-certificates parses
/// `SignerInfo.signedAttrs` as OPTIONAL, and when it is absent `CMS.isValidSignature` verifies the
/// signature directly over the `dataBytes` it is handed. So instead of hand-rolling the signature
/// math and the chain, this strips `[0] signedAttrs` out of the blob and passes the attribute bytes
/// as `dataBytes`. swift-certificates then locates the signer certificate, enforces its own
/// `digestAlgorithmFor(signatureAlgorithm) == digestAlgorithm` cross-check, verifies the signature
/// under the leaf's public key over exactly the bytes the issuer signed, and builds the chain
/// through the same `Verifier` and `PermissivePolicy` as the strict path. No second copy of the
/// `appleVerified` / `selfSigned` / `certChainIncomplete` mapping exists (user-approved §7 decision
/// 2026-08-04, recorded on ipass-10g).
///
/// **Why the digest comparison here is load-bearing, not belt-and-braces.** Removing `signedAttrs`
/// also removes the one signed attribute swift-certificates validates: it compares the
/// `messageDigest` attribute against the digest of the content, and it never looks at `contentType`
/// at all. Without re-doing that comparison, a tampered `manifest.json` would keep a perfectly
/// valid signature over its untouched attributes and verify. So this function refuses to prepare
/// the fallback unless the `messageDigest` attribute equals the digest of `manifestBytes` under the
/// SignerInfo's own `digestAlgorithm`, compared in constant time. Both halves of the binding are
/// read from ONE parse: the digest checked is lifted out of the very bytes returned as
/// `attributeBytes`, so no disagreement between swift-certificates' parse and this one can satisfy
/// one half against a structure the other never saw.
///
/// **Fails closed.** Returns `nil` - leaving the strict path's verdict in place, never relabelling
/// it - on anything other than a definite-length DER blob carrying a single SignerInfo with a
/// present `[0] signedAttrs` holding exactly one single-valued `messageDigest` whose digest matches.
/// Indefinite-length BER is rejected by `DER.parse` and so lands here too; the strict path accepts
/// BER, so the fallback is deliberately narrower than what it recovers from. Mirrors Android's
/// fail-closed floor.
internal func prepareWireOrderFallback(
    signatureBytes: [UInt8],
    manifestBytes: [UInt8]
) -> WireOrderSignedAttrs? {
    guard let parsed = try? ParsedCMS(signatureBytes: signatureBytes),
        let digestOID = leadingOID(of: parsed.signerInfoFields[2]),
        let messageDigest = soleMessageDigestValue(parsed.signedAttrsChildren),
        let actualDigest = digest(manifestBytes, using: digestOID),
        constantTimeEqual(messageDigest, actualDigest)
    else {
        return nil
    }
    return WireOrderSignedAttrs(
        attributeBytes: setTaggedEncoding(of: parsed.signedAttrsChildren),
        strippedSignatureBytes: parsed.serializedWithoutSignedAttrs()
    )
}

/// The parts of a single-signer CMS blob the fallback needs, navigated by hand because
/// swift-certificates' own `CMSContentInfo` / `CMSSignedData` / `CMSSignerInfo` are `internal` and
/// its parse of `signedAttrs` is what fails in the first place. `DER.parse` is used rather than
/// `BER.parse` because it applies no SET-ordering check while still rejecting indefinite lengths.
private struct ParsedCMS {
    /// `ContentInfo ::= SEQUENCE { contentType, [0] EXPLICIT content }`.
    let contentType: ASN1Node
    let signedDataTag: ASN1Identifier
    /// `SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, [0] certificates,
    /// [1] crls, signerInfos }` - the optional fields make the position of `signerInfos` variable,
    /// but it is always last.
    let signedDataFields: [ASN1Node]
    /// `SignerInfo ::= SEQUENCE { version, sid, digestAlgorithm, [0] signedAttrs, signatureAlgorithm,
    /// signature, [1] unsignedAttrs }`.
    let signerInfoFields: [ASN1Node]
    let signedAttrsChildren: [ASN1Node]

    /// SignerInfo's `[0] signedAttrs`, when present, always sits at this index: every field before
    /// it is mandatory.
    static let signedAttrsIndex = 3

    init(signatureBytes: [UInt8]) throws {
        let contentInfoFields = try Self.children(of: try DER.parse(signatureBytes))
        guard contentInfoFields.count == 2 else { throw FallbackShape.notSingleSignerCMS }
        contentType = contentInfoFields[0]

        let explicitContent = contentInfoFields[1]
        guard explicitContent.identifier == .init(tagWithNumber: 0, tagClass: .contextSpecific) else {
            throw FallbackShape.notSingleSignerCMS
        }
        signedDataTag = explicitContent.identifier

        let explicitChildren = try Self.children(of: explicitContent)
        guard explicitChildren.count == 1 else { throw FallbackShape.notSingleSignerCMS }
        signedDataFields = try Self.children(of: explicitChildren[0])

        guard let signerInfos = signedDataFields.last, signerInfos.identifier == .set else {
            throw FallbackShape.notSingleSignerCMS
        }
        let signers = try Self.children(of: signerInfos)
        // LOAD-BEARING, not defense-in-depth. swift-certificates rejects multi-signer envelopes with
        // "Too many signatures", but it never sees the extra signers here: the rebuild below always
        // emits exactly one SignerInfo, so a relaxed guard would silently hand the library a
        // single-signer blob and let a multi-signer envelope through. Mutation-tested.
        guard signers.count == 1 else { throw FallbackShape.notSingleSignerCMS }
        signerInfoFields = try Self.children(of: signers[0])

        guard signerInfoFields.count > Self.signedAttrsIndex else { throw FallbackShape.noSignedAttrs }
        let signedAttrs = signerInfoFields[Self.signedAttrsIndex]
        guard signedAttrs.identifier == .init(tagWithNumber: 0, tagClass: .contextSpecific) else {
            // No signedAttrs at all: the signature already covers the content directly, so there is
            // no attribute-ordering problem to recover from.
            throw FallbackShape.noSignedAttrs
        }
        signedAttrsChildren = try Self.children(of: signedAttrs)
    }

    /// Re-serializes the blob with the sole SignerInfo's `[0] signedAttrs` element dropped and every
    /// other node round-tripped in place. Nothing the signature covers is touched: the signature is
    /// over `signedAttrs`, which the caller passes separately as raw bytes lifted from this same
    /// parse.
    func serializedWithoutSignedAttrs() -> [UInt8] {
        var serializer = DER.Serializer()
        serializer.appendConstructedNode(identifier: .sequence) { contentInfo in
            contentInfo.serialize(contentType)
            contentInfo.appendConstructedNode(identifier: signedDataTag) { explicit in
                explicit.appendConstructedNode(identifier: .sequence) { signedData in
                    for field in signedDataFields.dropLast() {
                        signedData.serialize(field)
                    }
                    signedData.appendConstructedNode(identifier: .set) { signerInfos in
                        signerInfos.appendConstructedNode(identifier: .sequence) { signerInfo in
                            for (index, field) in signerInfoFields.enumerated()
                            where index != Self.signedAttrsIndex {
                                signerInfo.serialize(field)
                            }
                        }
                    }
                }
            }
        }
        return serializer.serializedBytes
    }

    private static func children(of node: ASN1Node) throws -> [ASN1Node] {
        guard case .constructed(let collection) = node.content else {
            throw FallbackShape.notSingleSignerCMS
        }
        return Array(collection)
    }

    enum FallbackShape: Error {
        case notSingleSignerCMS
        case noSignedAttrs
    }
}

/// `children` re-tagged as a real SET, preserving their order. `serializeSetOf` is deliberately not
/// used: it sorts, which would reproduce the very bytes the strict path already tried.
private func setTaggedEncoding(of children: [ASN1Node]) -> [UInt8] {
    var serializer = DER.Serializer()
    serializer.appendConstructedNode(identifier: .set) { attributes in
        for child in children {
            attributes.serialize(child)
        }
    }
    return serializer.serializedBytes
}

/// The one `messageDigest` attribute's one value, or `nil` if `attributes` holds a non-attribute
/// element, no `messageDigest`, more than one, or one carrying anything but a single OCTET STRING.
/// Requiring exactly one is what lets the caller treat the result as *the* digest the signature
/// commits to rather than a first-match guess.
private func soleMessageDigestValue(_ attributes: [ASN1Node]) -> [UInt8]? {
    var found: [UInt8]?
    for attribute in attributes {
        guard case .constructed(let fields) = attribute.content else { return nil }
        let children = Array(fields)
        guard children.count == 2,
            let attrType = try? ASN1ObjectIdentifier(derEncoded: children[0]),
            case .constructed(let valueNodes) = children[1].content
        else {
            return nil
        }
        guard attrType == CMSOID.messageDigest else { continue }
        if found != nil { return nil }
        let values = Array(valueNodes)
        guard values.count == 1, let octets = try? ASN1OctetString(derEncoded: values[0]) else {
            return nil
        }
        found = Array(octets.bytes)
    }
    return found
}

/// The digest of `bytes` under `oid`, or `nil` for a digest algorithm the kernel does not implement.
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

/// The `algorithm` field of an `AlgorithmIdentifier` SEQUENCE. `ASN1NodeCollection` is a `Sequence`,
/// not a `Collection`, so the first element is read through its iterator.
private func leadingOID(of node: ASN1Node) -> ASN1ObjectIdentifier? {
    guard case .constructed(let fields) = node.content else { return nil }
    var iterator = fields.makeIterator()
    guard let oidNode = iterator.next() else { return nil }
    return try? ASN1ObjectIdentifier(derEncoded: oidNode)
}
