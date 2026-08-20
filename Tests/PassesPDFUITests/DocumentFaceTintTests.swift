import Foundation
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

    /// Both arms paint their slot through the ONE shared `documentFace` helper
    /// (which routes through `resolvedFace` above), so the PDF and image
    /// surfaces cannot drift apart on the single thing `faceTint` touches.
    /// Source-pinned because the helper is free and private — nothing else
    /// stops an arm from growing its own background.
    @Test func bothArmsRouteTheirBackgroundThroughTheSharedFace() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PassesPDFUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/PassesPDFUI/DocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let shared = try #require(
            try? NSRegularExpression(pattern: #"\.background\(\s*documentFace\("#))
        let range = NSRange(text.startIndex..., in: text)
        let sites = shared.numberOfMatches(in: text, range: range)
        #expect(sites == 2, "expected the PDF and image arms' two shared-face sites, found \(sites)")
        // And no arm grows a face of its own beside the shared one: every
        // other `.background(` in the file is the full-screen banner's chrome.
        let any = try #require(try? NSRegularExpression(pattern: #"\.background\("#))
        let banner = try #require(
            try? NSRegularExpression(pattern: #"\.background\(style\.fullScreenBannerBackground"#))
        let bannerSites = banner.numberOfMatches(in: text, range: range)
        #expect(any.numberOfMatches(in: text, range: range) == sites + bannerSites)
    }
}
