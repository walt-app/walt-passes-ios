import Testing
import PassesCore

@testable import PassesUI

/// Mirror of Android's `PublicApiSurfaceTest` for the security-intent shape.
/// Locks the sealed-arm shape via exhaustive switch; adding or removing an arm
/// in `SecurityIntent` forces a compile-time conversation here.
@Suite("Security intent surface")
struct SecurityIntentSurfaceTests {

    @Test func securityIntentArmsAreReachableViaSwitch() {
        let source = SourceField(
            fieldKey: "support_url",
            fieldLabel: "Support",
            organizationName: "Acme"
        )
        let intents: [SecurityIntent] = [
            .url(B3UrlIntent(url: "https://example.com", sourceField: source)),
            .phone(PhoneIntent(phoneNumber: "+15551234567", sourceField: source)),
            .email(EmailIntent(emailAddress: "support@example.com", sourceField: source))
        ]
        let labels = intents.map { intent -> String in
            switch intent {
            case .url(let i): return "url:\(i.url)"
            case .phone(let i): return "phone:\(i.phoneNumber)"
            case .email(let i): return "email:\(i.emailAddress)"
            }
        }
        #expect(labels == [
            "url:https://example.com",
            "phone:+15551234567",
            "email:support@example.com"
        ])
    }

    @Test func b3UrlIntentRegistrableDomainDefaultsToNil() {
        let intent = B3UrlIntent(
            url: "https://example.com",
            sourceField: SourceField(fieldKey: "k", fieldLabel: "L", organizationName: "Org")
        )
        #expect(intent.registrableDomain == nil)
    }

    @Test func b3EmphasisStyleArmsAreReachableViaSwitch() {
        let labels = B3EmphasisStyle.allCases.map { style -> String in
            switch style {
            case .container: return "container"
            case .domainHero: return "domain-hero"
            }
        }
        #expect(labels == ["container", "domain-hero"])
    }

    @Test func signatureStatusToBandCoversEveryCase() {
        let pairs: [(SignatureStatus, SignatureBand)] = [
            (.unsigned, .untrusted),
            (.selfSigned, .selfSigned),
            (.appleVerified, .appleVerified),
            (.certChainIncomplete, .incomplete)
        ]
        for (status, expected) in pairs {
            #expect(status.band == expected)
        }
    }
}
