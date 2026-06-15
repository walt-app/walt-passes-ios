import PassesCore
import Testing

@testable import PassesUI

/// Pure coverage for `resolvePassDisplayIdentity` — the single source of truth for the
/// trust-caption rule. "Fenced" means wrapped in U+2068 / U+2069 (FSI/PDI). Mirrors
/// passes-android `PassDisplayIdentityTest`.
@Suite("PassDisplayIdentity")
struct PassDisplayIdentityTests {
    /// Locks the exact FSI/PDI-fenced output without going through `isolated` (which would
    /// be circular). Must match `PassesUICore.isolated`.
    private func fenced(_ s: String) -> String { "\u{2068}\(s)\u{2069}" }

    @Test func nullOverrideReturnsFencedOrgNameAsPrimaryAndNilEyebrow() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: nil)
        #expect(identity.primary == fenced("Acme"))
        #expect(identity.eyebrow == nil)
    }

    @Test func blankOverrideIsTreatedAsNoOverride() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "   ")
        #expect(identity.primary == fenced("Acme"))
        #expect(identity.eyebrow == nil)
    }

    @Test func emptyOverrideIsTreatedAsNoOverride() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "")
        #expect(identity.primary == fenced("Acme"))
        #expect(identity.eyebrow == nil)
    }

    @Test func distinctOverrideReturnsBothLinesFencedIndependently() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "Mom's flight home")
        #expect(identity.primary == fenced("Mom's flight home"))
        #expect(identity.eyebrow == fenced("Acme"))
    }

    @Test func overrideTrimmedBeforeFencing() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "  Mom's flight  ")
        #expect(identity.primary == fenced("Mom's flight"))
        #expect(identity.eyebrow == fenced("Acme"))
    }

    @Test func overrideEqualToOrgNameIsSuppressed() {
        // Case-insensitive equality means the override IS the signed identity; the trust
        // rule is satisfied trivially, so no eyebrow.
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "ACME")
        #expect(identity.primary == fenced("Acme"))
        #expect(identity.eyebrow == nil)
    }

    @Test func overrideEqualToOrgNameWithSurroundingWhitespaceIsSuppressed() {
        let identity = resolvePassDisplayIdentity(organizationName: "Acme", userLabel: "  acme  ")
        #expect(identity.primary == fenced("Acme"))
        #expect(identity.eyebrow == nil)
    }

    @Test func overrideSubstitutesOrgNameThroughLocalizedStrings() {
        // The eyebrow shows the *localized* signed identity, not the raw key.
        let identity = resolvePassDisplayIdentity(
            organizationName: "ORG_KEY",
            userLabel: "Mom's flight",
            localizedStrings: LocalizedStrings(entries: ["ORG_KEY": "Tixly"])
        )
        #expect(identity.primary == fenced("Mom's flight"))
        #expect(identity.eyebrow == fenced("Tixly"))
    }

    @Test func nilOverrideStillSubstitutesOrgNameThroughLocalizedStrings() {
        let identity = resolvePassDisplayIdentity(
            organizationName: "ORG_KEY",
            userLabel: nil,
            localizedStrings: LocalizedStrings(entries: ["ORG_KEY": "Tixly"])
        )
        #expect(identity.primary == fenced("Tixly"))
        #expect(identity.eyebrow == nil)
    }

    @Test func overrideSuppressedAgainstLocalizedOrgName() {
        // Suppression compares the override against the *substituted* org name.
        let identity = resolvePassDisplayIdentity(
            organizationName: "ORG_KEY",
            userLabel: "tixly",
            localizedStrings: LocalizedStrings(entries: ["ORG_KEY": "Tixly"])
        )
        #expect(identity.primary == fenced("Tixly"))
        #expect(identity.eyebrow == nil)
    }

    @Test func passOverloadDelegatesUsingPassOrganizationName() {
        let pass = Pass(
            type: .generic,
            serialNumber: "0",
            description: "fixture",
            organizationName: "Acme",
            colors: PassColors(foreground: ColorValue(rgb: 0)),
            frontFields: PassFields(primary: [PassField(key: "p", label: nil, value: "v")]),
            backFields: []
        )
        let identity = resolvePassDisplayIdentity(pass: pass, userLabel: "Mom's flight")
        #expect(identity.primary == fenced("Mom's flight"))
        #expect(identity.eyebrow == fenced("Acme"))
    }
}
