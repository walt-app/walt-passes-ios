import Testing
import PassesUICore

@testable import PassesPDFUI

/// Locks the public API surface of `PassesPDFUI`. Mirror of Android's
/// `DocumentPublicApiSurfaceTest`. Reads every nested theme field so a
/// rename or removal forces a deliberate update. The bytecode-scan part
/// of the Android test does not have a direct iOS analogue (Swift does
/// not emit Java class files for reflective string-scanning); the trust
/// invariants it enforces are upheld here by the structural shape locks
/// and by the surface tests' refusal to expose extraction APIs.
@Suite("DocumentPublicApiSurface")
struct DocumentPublicApiSurfaceTests {

    @Test func documentSemanticsExposesAllNineSlots() {
        let argb = ArgbColor(argb: 0xFF000000)
        // captionIconTint gets a distinct value so the read below proves
        // it is its own independent slot, not an alias of
        // captionForeground (it merely *defaults* to captionForeground
        // when a caller omits it).
        let iconTint = ArgbColor(argb: 0xFFFF8800)
        let semantics = DocumentSemantics(
            captionBackground: argb,
            captionForeground: argb,
            captionIconTint: iconTint,
            tileBackground: argb,
            tileForeground: argb,
            tileLabelForeground: argb,
            laneBackground: argb,
            documentBadgeBackground: argb,
            documentBadgeForeground: argb
        )
        #expect(semantics.captionBackground == argb)
        #expect(semantics.captionForeground == argb)
        #expect(semantics.captionIconTint == iconTint)
        #expect(semantics.tileBackground == argb)
        #expect(semantics.tileForeground == argb)
        #expect(semantics.tileLabelForeground == argb)
        #expect(semantics.laneBackground == argb)
        #expect(semantics.documentBadgeBackground == argb)
        #expect(semantics.documentBadgeForeground == argb)
    }

    @Test func documentSemanticsCaptionIconTintDefaultsToCaptionForeground() {
        let foreground = ArgbColor(argb: 0xFF123456)
        let other = ArgbColor(argb: 0xFF000000)
        let semantics = DocumentSemantics(
            captionBackground: other,
            captionForeground: foreground,
            tileBackground: other,
            tileForeground: other,
            tileLabelForeground: other,
            laneBackground: other,
            documentBadgeBackground: other,
            documentBadgeForeground: other
        )
        #expect(semantics.captionIconTint == foreground)
    }

    @Test func fullScreenBannerColorsDefaultToDocumentBadgeColors() {
        let other = ArgbColor(argb: 0xFF000000)
        let bg = ArgbColor(argb: 0xFFAABBCC)
        let fg = ArgbColor(argb: 0xFF112233)
        let semantics = DocumentSemantics(
            captionBackground: other,
            captionForeground: other,
            tileBackground: other,
            tileForeground: other,
            tileLabelForeground: other,
            laneBackground: other,
            documentBadgeBackground: bg,
            documentBadgeForeground: fg
        )
        #expect(semantics.fullScreenBannerBackground == bg)
        #expect(semantics.fullScreenBannerForeground == fg)
    }

    @Test func fullScreenBannerLabelHasEnglishPlaceholderDefault() {
        // Production hosts override; this default is documented soft.
        let other = ArgbColor(argb: 0xFF000000)
        let semantics = DocumentSemantics(
            captionBackground: other,
            captionForeground: other,
            tileBackground: other,
            tileForeground: other,
            tileLabelForeground: other,
            laneBackground: other,
            documentBadgeBackground: other,
            documentBadgeForeground: other
        )
        #expect(semantics.fullScreenBannerLabel == "Tap for full screen")
        #expect(semantics.closeFullScreenLabel == "Close")
    }
}
