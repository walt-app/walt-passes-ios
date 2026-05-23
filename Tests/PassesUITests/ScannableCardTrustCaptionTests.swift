import Testing

@testable import PassesUI

@Suite("ScannableCardTrustCaption")
struct ScannableCardTrustCaptionTests {

    @Test func captionTextIsLiteralCreatedByYou() {
        // The wording is the load-bearing part of SCANNABLE_CARD_THREAT_MODEL.md
        // C2; a contributor changing this string is making a security-policy edit
        // and this assertion forces the conversation.
        #expect(ScannableCardTrustCaption.captionText == "Created by you")
    }
}

@Suite("SecuritySheets hero extraction")
struct SecurityHeroTests {

    @Test func phoneHeroCollapsesAdjacentSpaces() {
        #expect(phoneHero("  +44  20  7946  0958  ") == "+44 20 7946 0958")
    }

    @Test func emailHostHeroExtractsHostPortion() {
        #expect(emailHostHero("support@phisher.example") == "phisher.example")
    }

    @Test func emailHostHeroFallsBackToFullAddressForIllFormed() {
        #expect(emailHostHero("not-an-email") == "not-an-email")
    }

    @Test func emailHostHeroHandlesTrailingAt() {
        // "@" at end has no host portion; fall back to the verbatim address.
        #expect(emailHostHero("trailing@") == "trailing@")
    }
}
