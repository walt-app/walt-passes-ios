import Foundation
import PassesUICore

/// The theming contract the host supplies to `PassesUI`. Mirror of Android's
/// `is.walt.passes.ui.theme.PassesSemantics`.
///
/// PassesUI deliberately does NOT define its own SwiftUI palette or typography.
/// The host's surrounding theme (system colors, the app's color set, dynamic type)
/// supplies the chrome. `PassesSemantics` adds the slots that have no system
/// analogue and are specific to pass rendering and security confirmation.
public struct PassesSemantics: Sendable, Equatable {
    public let signatureBadge: SignatureBadgeColors
    public let expiredBadge: ExpiredBadgeStyle
    public let securitySheet: SecuritySheetStyle
    public let categoryAccent: CategoryAccentColors
    public let unverifiedArtifact: UnverifiedArtifactStyle

    public init(
        signatureBadge: SignatureBadgeColors,
        expiredBadge: ExpiredBadgeStyle,
        securitySheet: SecuritySheetStyle,
        categoryAccent: CategoryAccentColors,
        unverifiedArtifact: UnverifiedArtifactStyle = .placeholder
    ) {
        self.signatureBadge = signatureBadge
        self.expiredBadge = expiredBadge
        self.securitySheet = securitySheet
        self.categoryAccent = categoryAccent
        self.unverifiedArtifact = unverifiedArtifact
    }
}

/// Color slots for the trust badge on every rendered pass. Four slots mirror
/// `SignatureStatusKind`; adding an arm there forces a corresponding addition here.
public struct SignatureBadgeColors: Sendable, Equatable {
    public let unsignedBackground: ArgbColor
    public let unsignedForeground: ArgbColor
    public let selfSignedBackground: ArgbColor
    public let selfSignedForeground: ArgbColor
    public let appleVerifiedBackground: ArgbColor
    public let appleVerifiedForeground: ArgbColor
    public let certChainIncompleteBackground: ArgbColor
    public let certChainIncompleteForeground: ArgbColor

    public init(
        unsignedBackground: ArgbColor,
        unsignedForeground: ArgbColor,
        selfSignedBackground: ArgbColor,
        selfSignedForeground: ArgbColor,
        appleVerifiedBackground: ArgbColor,
        appleVerifiedForeground: ArgbColor,
        certChainIncompleteBackground: ArgbColor,
        certChainIncompleteForeground: ArgbColor
    ) {
        self.unsignedBackground = unsignedBackground
        self.unsignedForeground = unsignedForeground
        self.selfSignedBackground = selfSignedBackground
        self.selfSignedForeground = selfSignedForeground
        self.appleVerifiedBackground = appleVerifiedBackground
        self.appleVerifiedForeground = appleVerifiedForeground
        self.certChainIncompleteBackground = certChainIncompleteBackground
        self.certChainIncompleteForeground = certChainIncompleteForeground
    }
}

/// Visual treatment of the non-suppressible expired/voided overlay. `scrimAlpha`
/// is the 0...255 alpha of the dim layer; the RGB comes from the host's chrome.
public struct ExpiredBadgeStyle: Sendable, Equatable {
    public let pillBackground: ArgbColor
    public let pillForeground: ArgbColor
    public let scrimAlpha: Int

    public init(pillBackground: ArgbColor, pillForeground: ArgbColor, scrimAlpha: Int) {
        self.pillBackground = pillBackground
        self.pillForeground = pillForeground
        self.scrimAlpha = scrimAlpha
    }
}

/// Styling for the URL / phone / email confirmation sheets. The sheets visibly
/// depart from neutral chrome so muscle-memory dismissal is harder.
public struct SecuritySheetStyle: Sendable, Equatable {
    public let sheetBackground: ArgbColor
    public let emphasisBackground: ArgbColor
    public let emphasisForeground: ArgbColor
    public let bodyForeground: ArgbColor
    public let confirmContainer: ArgbColor
    public let confirmForeground: ArgbColor
    public let cancelForeground: ArgbColor
    public let eyebrowForeground: ArgbColor
    public let mutedForeground: ArgbColor

    public init(
        sheetBackground: ArgbColor,
        emphasisBackground: ArgbColor,
        emphasisForeground: ArgbColor,
        bodyForeground: ArgbColor,
        confirmContainer: ArgbColor,
        confirmForeground: ArgbColor,
        cancelForeground: ArgbColor,
        eyebrowForeground: ArgbColor = ArgbColor(argb: 0xFF73777F),
        mutedForeground: ArgbColor = ArgbColor(argb: 0xFFC4C7C5)
    ) {
        self.sheetBackground = sheetBackground
        self.emphasisBackground = emphasisBackground
        self.emphasisForeground = emphasisForeground
        self.bodyForeground = bodyForeground
        self.confirmContainer = confirmContainer
        self.confirmForeground = confirmForeground
        self.cancelForeground = cancelForeground
        self.eyebrowForeground = eyebrowForeground
        self.mutedForeground = mutedForeground
    }
}

/// Per-`PassType` accent strip colors used inside the wallet list.
public struct CategoryAccentColors: Sendable, Equatable {
    public let boardingPass: ArgbColor
    public let eventTicket: ArgbColor
    public let coupon: ArgbColor
    public let storeCard: ArgbColor
    public let generic: ArgbColor

    public init(
        boardingPass: ArgbColor,
        eventTicket: ArgbColor,
        coupon: ArgbColor,
        storeCard: ArgbColor,
        generic: ArgbColor
    ) {
        self.boardingPass = boardingPass
        self.eventTicket = eventTicket
        self.coupon = coupon
        self.storeCard = storeCard
        self.generic = generic
    }
}

/// Visual treatment for a user-generated, unsigned scannable artifact
/// (`ScannableCard`). Powers the chrome around `ScannableCardTile` and
/// `ScannableCardScreen`, both of which must read as a different artifact class
/// from a verified PKPASS tile at a glance.
public struct UnverifiedArtifactStyle: Sendable, Equatable {
    public let accent: ArgbColor
    public let captionBackground: ArgbColor
    public let captionForeground: ArgbColor
    public let captionIconTint: ArgbColor

    public init(
        accent: ArgbColor,
        captionBackground: ArgbColor,
        captionForeground: ArgbColor,
        captionIconTint: ArgbColor? = nil
    ) {
        self.accent = accent
        self.captionBackground = captionBackground
        self.captionForeground = captionForeground
        self.captionIconTint = captionIconTint ?? captionForeground
    }

    /// Neutral grayscale placeholder so previews and tests render without a host
    /// theme. Hosts MUST override in production.
    public static let placeholder = UnverifiedArtifactStyle(
        accent: ArgbColor(argb: 0xFF6B6B6B),
        captionBackground: ArgbColor(argb: 0xFFF2F2F2),
        captionForeground: ArgbColor(argb: 0xFF202020)
    )
}
