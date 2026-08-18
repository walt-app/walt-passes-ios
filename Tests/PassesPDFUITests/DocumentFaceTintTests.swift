import CoreGraphics
import PassesPDFCore
import PassesUICore
import Testing

@testable import PassesPDFUI

/// Pins the faceTint contract on `DocumentView` (wpass-80y.2/.5 mirror): the
/// face decision routes through the shared gate in BOTH directions, and the
/// page render request is derived from the slot and the baseline budget alone
/// — the tint cannot change what reaches the renderer (Android's
/// `DocumentFaceTintTest` claim, pinned here at the pure seams since iOS unit
/// tests cannot drive a composed pager).
struct DocumentFaceTintTests {

    @Test func resolvedFaceTakesAnOpaqueTint() {
        let denim = ArgbColor(argb: 0xFFCE_E6FF)
        #expect(DocumentView.resolvedFace(denim) == denim)
    }

    @Test func resolvedFaceFallsBackForNilAndTransparentTints() {
        #expect(DocumentView.resolvedFace(nil) == nil)
        // Transparent-but-specified is the wpass-80y.5 bug arm.
        #expect(DocumentView.resolvedFace(ArgbColor(argb: 0x00CE_E6FF)) == nil)
    }

    @Test func renderTargetIsDerivedFromSlotAndBaselineOnly() {
        // `pageRenderTarget` takes no tint BY TYPE — the structural half of
        // "the tint reaches the frame and nothing else". Pin the derivation at
        // a slot below the baseline budget (floored) and one above (adopted).
        let small = DocumentView.pageRenderTarget(page: 2, slot: CGSize(width: 200, height: 300))
        #expect(small.page == 2)
        #expect(small.widthPx == DocumentView.targetPageWidthPx)
        #expect(small.heightPx == DocumentView.targetPageHeightPx)

        let large = DocumentView.pageRenderTarget(page: 0, slot: CGSize(width: 800, height: 1000))
        #expect(large.widthPx == 800)
        #expect(large.heightPx == 1000)
    }
}
