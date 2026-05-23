import Foundation
import PassesUICore

/// The theming contract that the host supplies to `PassesPDFUI`. Mirror of
/// `is.walt.passes.pdf.ui.theme.DocumentSemantics`.
///
/// Sibling shape to `PassesUI::PassesSemantics`: both modules ask the host for
/// semantic color slots that have no system analogue. The two contracts are
/// deliberately independent — a host that only renders passes wires
/// `PassesSemantics`; a host that adds documents wires `DocumentSemantics`
/// alongside, neither nested inside the other.
///
/// `captionBackground` / `captionForeground` / `captionIconTint` style the
/// non-suppressible "user-provided document" caption. The caption itself is
/// structurally always-on (see `DocumentTrustCaption`); these slots restyle
/// it but cannot hide it. A host wanting a flat, borderless treatment sets
/// `captionBackground` transparent.
///
/// `captionIconTint` defaults to `captionForeground` so a consumer that does
/// not opt in to an accent gets a consistent monochrome caption.
public struct DocumentSemantics: Sendable, Equatable {
    public let captionBackground: ArgbColor
    public let captionForeground: ArgbColor
    public let captionIconTint: ArgbColor
    public let tileBackground: ArgbColor
    public let tileForeground: ArgbColor
    public let tileLabelForeground: ArgbColor
    public let laneBackground: ArgbColor
    public let documentBadgeBackground: ArgbColor
    public let documentBadgeForeground: ArgbColor
    /// Label and colour slots for the in-view "tap for full screen" banner.
    /// Defaults keep the addition non-breaking and provide English placeholder
    /// copy for tests; production hosts override with localised strings.
    public let fullScreenBannerLabel: String
    public let fullScreenBannerBackground: ArgbColor
    public let fullScreenBannerForeground: ArgbColor
    /// Label for the close affordance on the full-screen surface.
    public let closeFullScreenLabel: String

    public init(
        captionBackground: ArgbColor,
        captionForeground: ArgbColor,
        captionIconTint: ArgbColor? = nil,
        tileBackground: ArgbColor,
        tileForeground: ArgbColor,
        tileLabelForeground: ArgbColor,
        laneBackground: ArgbColor,
        documentBadgeBackground: ArgbColor,
        documentBadgeForeground: ArgbColor,
        fullScreenBannerLabel: String = "Tap for full screen",
        fullScreenBannerBackground: ArgbColor? = nil,
        fullScreenBannerForeground: ArgbColor? = nil,
        closeFullScreenLabel: String = "Close"
    ) {
        self.captionBackground = captionBackground
        self.captionForeground = captionForeground
        self.captionIconTint = captionIconTint ?? captionForeground
        self.tileBackground = tileBackground
        self.tileForeground = tileForeground
        self.tileLabelForeground = tileLabelForeground
        self.laneBackground = laneBackground
        self.documentBadgeBackground = documentBadgeBackground
        self.documentBadgeForeground = documentBadgeForeground
        self.fullScreenBannerLabel = fullScreenBannerLabel
        self.fullScreenBannerBackground = fullScreenBannerBackground ?? documentBadgeBackground
        self.fullScreenBannerForeground = fullScreenBannerForeground ?? documentBadgeForeground
        self.closeFullScreenLabel = closeFullScreenLabel
    }
}
