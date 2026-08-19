import PassesPDFCore
import PassesUICore
import Testing

@testable import PassesPDFUI

/// Pins the faceTint contract on `DocumentView` (wpass-80y.2/.5 mirror): the
/// face decision routes through the shared gate in BOTH directions. Since
/// ios-dts.16 (render-once) pages are stored rasters — there is no render
/// request for a tint to influence, so Android's "tint cannot change what
/// reaches the renderer" claim is now structural (the view holds no renderer
/// at all) and needs no pure-seam pin.
@MainActor
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
}
