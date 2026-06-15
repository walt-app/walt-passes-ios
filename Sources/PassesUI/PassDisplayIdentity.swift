import Foundation
import PassesCore
import PassesUICore

/// Resolved visible identity for a pkpass, suitable for any consumer-authored title +
/// subtitle row (and used by `PassIdentityBlock`).
///
/// Both strings are already FSI/PDI-fenced via `isolated`; callers MUST NOT re-wrap them
/// and MUST NOT inline the equality / trim / locale-substitution logic themselves. Rendering
/// `primary` alone when `eyebrow` is non-nil is a trust-claim violation: the signed
/// `organizationName` MUST be shown on the same surface whenever an override is active.
///
/// - `primary`: the fenced primary label — the fenced override when one survives the rules,
///   otherwise the fenced (localized) signed `organizationName`.
/// - `eyebrow`: the fenced signed `organizationName`, present only when an override is active
///   and distinct from the signed identity. `nil` means the primary already IS the signed
///   identity and the trust rule is satisfied trivially.
public struct PassDisplayIdentity: Sendable, Equatable {
    public let primary: String
    public let eyebrow: String?

    public init(primary: String, eyebrow: String?) {
        self.primary = primary
        self.eyebrow = eyebrow
    }
}

/// Computes the resolved visible identity. Primitive form; the single source of truth for the
/// trust-caption rule. Rules, in order:
///  1. Substitute `organizationName` through `localizedStrings` (misses fall through to raw).
///  2. Trim `userLabel`; treat empty as no-override.
///  3. Case-insensitively compare the trimmed override to the trimmed substituted
///     `organizationName`; equality suppresses the override.
///  4. FSI/PDI-fence both surviving lines via `isolated`.
///
/// Pass `LocalizedStrings.empty` when no strings table is available; every lookup becomes a
/// pass-through and the raw `organizationName` is fenced verbatim.
public func resolvePassDisplayIdentity(
    organizationName: String,
    userLabel: String?,
    localizedStrings: LocalizedStrings = .empty
) -> PassDisplayIdentity {
    let displayOrganizationName = localizedStrings.lookupOrSelf(organizationName)
    let override = userLabel?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmptyUnless(caseInsensitivelyEqualTo: displayOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines))

    if let override {
        return PassDisplayIdentity(primary: isolated(override), eyebrow: isolated(displayOrganizationName))
    }
    return PassDisplayIdentity(primary: isolated(displayOrganizationName), eyebrow: nil)
}

/// The `Pass`-bearing convenience overload. Resolves the pass's strings table for `locale`
/// via Apple's documented locale-fallback chain and delegates to the primitive above.
/// Detail-view callers holding a full `Pass` should prefer this; list-row callers holding
/// only a `PassSummary` should call the primitive directly with `LocalizedStrings.empty`.
public func resolvePassDisplayIdentity(
    pass: Pass,
    userLabel: String?,
    locale: PassLocale = PassLocale("en")
) -> PassDisplayIdentity {
    resolvePassDisplayIdentity(
        organizationName: pass.organizationName,
        userLabel: userLabel,
        localizedStrings: pass.resolveLocalizedStrings(preferred: locale)
    )
}

private extension String {
    /// Returns `self` unless it is empty or case-insensitively equal to `other`, in which
    /// case it returns `nil` (the override is suppressed).
    func nonEmptyUnless(caseInsensitivelyEqualTo other: String) -> String? {
        guard !isEmpty, caseInsensitiveCompare(other) != .orderedSame else { return nil }
        return self
    }
}
