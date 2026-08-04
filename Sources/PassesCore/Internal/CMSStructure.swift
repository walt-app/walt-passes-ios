import Foundation
import SwiftASN1

/// OIDs the CMS pre-passes and the wire-order fallback match on.
internal enum CMSOID {
    static let rsaEncryption: ASN1ObjectIdentifier = "1.2.840.113549.1.1.1"
    static let sha1: ASN1ObjectIdentifier = "1.3.14.3.2.26"
    static let sha256: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.1"
    static let sha384: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.2"
    static let sha512: ASN1ObjectIdentifier = "2.16.840.1.101.3.4.2.3"
    static let sha1WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.5"
    static let sha256WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.11"
    static let sha384WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.12"
    static let sha512WithRSA: ASN1ObjectIdentifier = "1.2.840.113549.1.1.13"
    static let messageDigest: ASN1ObjectIdentifier = "1.2.840.113549.1.9.4"

    /// The `shaNNNWithRSAEncryption` OID implied by an RSA signer whose digest is `digest`.
    static func combinedRSA(forDigest digest: ASN1ObjectIdentifier) -> ASN1ObjectIdentifier? {
        switch digest {
        case sha1: return sha1WithRSA
        case sha256: return sha256WithRSA
        case sha384: return sha384WithRSA
        case sha512: return sha512WithRSA
        default: return nil
        }
    }

    static let knownDigests: [ASN1ObjectIdentifier] = [sha1, sha256, sha384, sha512]
}

/// The children of a constructed node, or nil for a primitive. Callers map nil onto their own error.
internal func constructedChildren(of node: ASN1Node) -> [ASN1Node]? {
    guard case .constructed(let collection) = node.content else { return nil }
    return Array(collection)
}

/// The `algorithm` field of an `AlgorithmIdentifier` SEQUENCE. `ASN1NodeCollection` is a `Sequence`,
/// not a `Collection`, so the first element is read through its iterator.
internal func leadingOID(of node: ASN1Node) -> ASN1ObjectIdentifier? {
    guard case .constructed(let fields) = node.content else { return nil }
    var iterator = fields.makeIterator()
    guard let oidNode = iterator.next() else { return nil }
    return try? ASN1ObjectIdentifier(derEncoded: oidNode)
}

/// A single-signer detached CMS blob, navigated by hand.
///
/// Needed because swift-certificates' own `CMSContentInfo` / `CMSSignedData` / `CMSSignerInfo` are
/// `internal`, and because its `signedAttrs` parse is the thing that fails in the wire-order case.
/// `DER.parse` applies no SET-ordering check while still rejecting indefinite-length BER, so it sees
/// blobs the library's own parse refuses.
///
/// Returns nil for anything but a single-signer, definite-length blob: multi-signer envelopes are
/// outside the trust claim, and every consumer here fails closed.
internal struct CMSStructure {
    /// `SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, [0] certificates,
    /// [1] crls, signerInfos }`. The optional fields make `signerInfos`' position vary, but it is
    /// always last.
    static let digestAlgorithmsIndex = 1
    /// `SignerInfo ::= SEQUENCE { version, sid, digestAlgorithm, [0] signedAttrs, signatureAlgorithm,
    /// signature, [1] unsignedAttrs }`.
    static let digestAlgorithmIndex = 2
    static let signedAttrsIndex = 3

    private let contentInfoTag: ASN1Identifier
    private let contentType: ASN1Node
    private let explicitContentTag: ASN1Identifier
    private let signedDataTag: ASN1Identifier
    private let signerInfosTag: ASN1Identifier
    private let signerInfoTag: ASN1Identifier

    let signedDataFields: [ASN1Node]
    let signerInfoFields: [ASN1Node]

    init?(signatureBytes: [UInt8]) {
        guard let root = try? DER.parse(signatureBytes),
            let contentInfoFields = constructedChildren(of: root),
            contentInfoFields.count == 2
        else {
            return nil
        }
        contentInfoTag = root.identifier
        contentType = contentInfoFields[0]

        let explicitContent = contentInfoFields[1]
        guard explicitContent.identifier == .init(tagWithNumber: 0, tagClass: .contextSpecific),
            let explicitChildren = constructedChildren(of: explicitContent),
            explicitChildren.count == 1,
            let signedDataFields = constructedChildren(of: explicitChildren[0]),
            signedDataFields.count > Self.digestAlgorithmsIndex
        else {
            return nil
        }
        explicitContentTag = explicitContent.identifier
        signedDataTag = explicitChildren[0].identifier
        self.signedDataFields = signedDataFields

        // The single-signer floor is load-bearing for the wire-order fallback, not just a restatement
        // of the library's "Too many signatures": `reserialized` emits exactly one SignerInfo, so a
        // relaxed guard would hand the library a single-signer blob and let a multi-signer envelope
        // through. Mutation-tested.
        guard let signerInfos = signedDataFields.last, signerInfos.identifier == .set,
            let signers = constructedChildren(of: signerInfos), signers.count == 1,
            let signerInfoFields = constructedChildren(of: signers[0]),
            signerInfoFields.count > Self.signedAttrsIndex
        else {
            return nil
        }
        signerInfosTag = signerInfos.identifier
        signerInfoTag = signers[0].identifier
        self.signerInfoFields = signerInfoFields
    }

    /// The SignerInfo's `digestAlgorithm`. Safe to subscript: `init` requires more fields than this.
    var digestAlgorithm: ASN1Node { signerInfoFields[Self.digestAlgorithmIndex] }

    /// `signatureAlgorithm` sits after `signedAttrs` when present, in its place when absent.
    var signatureAlgorithmIndex: Int {
        signedAttrsChildren == nil ? Self.signedAttrsIndex : Self.signedAttrsIndex + 1
    }

    /// The SignerInfo's `signatureAlgorithm`, or nil when the blob is too short to hold one.
    var signatureAlgorithm: ASN1Node? {
        let index = signatureAlgorithmIndex
        return index < signerInfoFields.count ? signerInfoFields[index] : nil
    }

    /// The SignedData-level `digestAlgorithms` SET, which the library requires to contain the
    /// signer's own `digestAlgorithm`.
    var declaredDigestAlgorithms: [ASN1Node]? {
        constructedChildren(of: signedDataFields[Self.digestAlgorithmsIndex])
    }

    /// The SignerInfo's `[0] signedAttrs`, or nil when absent - in which case the signature already
    /// covers the content directly and there is no attribute-ordering problem to recover from.
    var signedAttrsChildren: [ASN1Node]? {
        let candidate = signerInfoFields[Self.signedAttrsIndex]
        guard candidate.identifier == .init(tagWithNumber: 0, tagClass: .contextSpecific) else {
            return nil
        }
        return constructedChildren(of: candidate)
    }

    /// Re-serializes the blob, substituting the children of the SignedData `digestAlgorithms` SET and
    /// of the sole SignerInfo. Every identifier is round-tripped from the parse, so a validly but
    /// unusually tagged blob is not silently canonicalized. Nothing any signature covers is altered:
    /// certificates are re-emitted verbatim, and `signedAttrs` is only ever dropped by a caller that
    /// verifies over the original attribute bytes it lifted from this same parse.
    func reserialized(
        digestAlgorithms: ((inout DER.Serializer) throws -> Void)? = nil,
        signerInfo: (inout DER.Serializer) throws -> Void
    ) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: contentInfoTag) { contentInfo in
            contentInfo.serialize(contentType)
            try contentInfo.appendConstructedNode(identifier: explicitContentTag) { explicit in
                try explicit.appendConstructedNode(identifier: signedDataTag) { signedData in
                    for (index, field) in signedDataFields.dropLast().enumerated() {
                        if index == Self.digestAlgorithmsIndex, let digestAlgorithms {
                            try signedData.appendConstructedNode(identifier: field.identifier) { set in
                                try digestAlgorithms(&set)
                            }
                        } else {
                            signedData.serialize(field)
                        }
                    }
                    try signedData.appendConstructedNode(identifier: signerInfosTag) { signerInfos in
                        try signerInfos.appendConstructedNode(identifier: signerInfoTag) { info in
                            try signerInfo(&info)
                        }
                    }
                }
            }
        }
        return serializer.serializedBytes
    }
}

/// Serializes `AlgorithmIdentifier ::= SEQUENCE { algorithm, parameters }`. Throws rather than
/// swallowing, so a caller that cannot re-encode leaves the blob untouched instead of emitting a
/// malformed SEQUENCE.
internal func serializeAlgorithmIdentifier(
    _ oid: ASN1ObjectIdentifier,
    nullParameters: Bool = true,
    into serializer: inout DER.Serializer
) throws {
    try serializer.appendConstructedNode(identifier: .sequence) { fields in
        try fields.serialize(oid)
        if nullParameters {
            try fields.serialize(ASN1Null())
        }
    }
}
