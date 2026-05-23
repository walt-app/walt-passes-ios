import Foundation

/// A user-generated, unsigned scannable artifact. Sibling of `Pass`, NOT a subtype: existence
/// of a `ScannableCard` value asserts that the wrapped payload has cleared the kernel's
/// validator (length caps, charset rules, bidi/control-character rejection). The initializer
/// is `internal` so this invariant cannot be bypassed by an outside caller hand-building one
/// around raw input — the only construction path is via the validator's
/// `ScannableCardCreateResult.success`.
///
/// Where `Pass` carries a sibling `SignatureStatus` to convey trust, `ScannableCard` carries
/// trust at the type level instead — there is no signature to validate because the user typed
/// the data. The two artifact classes deliberately share no supertype; introducing one would
/// re-create the trust-conflation risk the wpass-lzi epic forbids.
public struct ScannableCard: Sendable, Equatable {
    public let id: ScannableCardId
    public let payload: String
    public let format: ScannableFormat
    public let label: String
    public let createdAt: PassInstant

    internal init(
        id: ScannableCardId,
        payload: String,
        format: ScannableFormat,
        label: String,
        createdAt: PassInstant
    ) {
        self.id = id
        self.payload = payload
        self.format = format
        self.label = label
        self.createdAt = createdAt
    }
}

/// Type-safe identifier for a `ScannableCard`. passes-core does not mint IDs; the storage
/// module assigns one on insert and consumers pass that value back through here for any
/// subsequent reference.
public struct ScannableCardId: Sendable, Equatable, Hashable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}
