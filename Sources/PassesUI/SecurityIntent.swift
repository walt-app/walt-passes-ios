import Foundation

/// The three security-confirmation intent families that PassesUI mediates
/// between a tapped pass field and the host's outbound action. Each intent
/// carries the exact string that will leave the device if the user confirms.
/// Mirror of Android's `is.walt.passes.ui.SecurityIntent`.
public enum SecurityIntent: Sendable, Equatable {
    case url(B3UrlIntent)
    case phone(PhoneIntent)
    case email(EmailIntent)

    public var sourceField: SourceField {
        switch self {
        case .url(let i): return i.sourceField
        case .phone(let i): return i.sourceField
        case .email(let i): return i.sourceField
        }
    }
}

/// A URL detected in a pass back-field value. `registrableDomain` is a
/// best-effort, PSL-free presentation aid; `url` carries the trust contract.
/// Consumers MUST NOT route `registrableDomain` into any outbound action.
public struct B3UrlIntent: Sendable, Equatable {
    public let url: String
    public let sourceField: SourceField
    public let registrableDomain: String?

    public init(url: String, sourceField: SourceField, registrableDomain: String? = nil) {
        self.url = url
        self.sourceField = sourceField
        self.registrableDomain = registrableDomain
    }
}

public struct PhoneIntent: Sendable, Equatable {
    public let phoneNumber: String
    public let sourceField: SourceField

    public init(phoneNumber: String, sourceField: SourceField) {
        self.phoneNumber = phoneNumber
        self.sourceField = sourceField
    }
}

public struct EmailIntent: Sendable, Equatable {
    public let emailAddress: String
    public let sourceField: SourceField

    public init(emailAddress: String, sourceField: SourceField) {
        self.emailAddress = emailAddress
        self.sourceField = sourceField
    }
}

/// Where in the pass the security-relevant value originated. All three values
/// are sourced from the parsed `Pass`; none are user-supplied at the call site.
public struct SourceField: Sendable, Equatable {
    public let fieldKey: String
    public let fieldLabel: String?
    public let organizationName: String

    public init(fieldKey: String, fieldLabel: String?, organizationName: String) {
        self.fieldKey = fieldKey
        self.fieldLabel = fieldLabel
        self.organizationName = organizationName
    }
}

/// Layout option for the three confirmation sheets. Default is `.container`,
/// behavior-identical to the original. `.domainHero` is the trust-claim-safer
/// alternative for hosts that surface a Verified signal elsewhere on the same
/// screen. Mirror of Android's `B3EmphasisStyle`.
public enum B3EmphasisStyle: Sendable, Equatable, CaseIterable {
    case container
    case domainHero
}
