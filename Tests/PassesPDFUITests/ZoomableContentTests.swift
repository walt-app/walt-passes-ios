import Foundation
import PassesPDFCore
import SwiftUI
import Testing

@testable import PassesPDFUI

/// Pins the shared zoom primitive (ios-dts.12, wpass-pl7.4 mirror): the
/// constants, the pan clamp math, and — structurally — THE CLIP LESSON: the
/// scaled layer draws outside its layout bounds, so the clip must sit on the
/// unscaled ancestor. The Android pixel test (`ZoomableImageClipTest`) cannot
/// run here; the iOS analogue makes the property structural instead — one
/// scale site, one file, clip outside it.
struct ZoomableContentTests {

    private typealias Zoom = ZoomableContent<EmptyView>

    @Test func zoomConstantsMatchAndroid() {
        #expect(Zoom.minScale == 1)
        #expect(Zoom.maxScale == 5)
        #expect(Zoom.doubleTapScale == 2)
    }

    @Test func scaleClampsToTheRoster() {
        #expect(Zoom.clampScale(0.2) == 1)
        #expect(Zoom.clampScale(3) == 3)
        #expect(Zoom.clampScale(9) == 5)
    }

    @Test func panClampsToScaleMinusOneTimesHalfSlot() {
        let slot = CGSize(width: 400, height: 800)
        // At 3x the bound is ±((3-1)×slot/2) = ±(400, 800).
        let inside = Zoom.clampOffset(CGSize(width: 100, height: -200), scale: 3, slot: slot)
        #expect(inside == CGSize(width: 100, height: -200))
        let outside = Zoom.clampOffset(CGSize(width: 999, height: -9999), scale: 3, slot: slot)
        #expect(outside == CGSize(width: 400, height: -800))
        // At 1x the content is pinned centered.
        let pinned = Zoom.clampOffset(CGSize(width: 50, height: 50), scale: 1, slot: slot)
        #expect(pinned == .zero)
    }

    /// The clip lesson, structurally: every `scaleEffect` in this module lives
    /// in ZoomableContent.swift (both arms route zoom through the ONE
    /// primitive), and that file's `.clipped()` sits on the unscaled ancestor
    /// — textually AFTER the scale site, on the container that wraps it.
    @Test func everyScaleSiteLivesUnderTheUnscaledClip() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI")
        let files = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scaleFiles: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".scaleEffect(") {
                scaleFiles.append(url.lastPathComponent)
            }
            if url.lastPathComponent == "ZoomableContent.swift" {
                // Comments restate the lesson; only CODE lines carry the pin.
                let code = text.components(separatedBy: .newlines)
                    .map { $0.components(separatedBy: "//").first ?? $0 }
                    .joined(separator: "\n")
                let scaleIndex = try #require(code.range(of: ".scaleEffect("))
                let clipIndex = try #require(
                    code.range(of: ".clipped()"),
                    "the unscaled-ancestor clip is the load-bearing line")
                #expect(
                    scaleIndex.lowerBound < clipIndex.lowerBound,
                    "the clip must wrap the scaled layer, not precede it")
                #expect(
                    code.components(separatedBy: ".scaleEffect(").count == 2,
                    "one scale site — a second would escape the shared clip")
            }
        }
        #expect(scaleFiles == ["ZoomableContent.swift"], "zoom escaped the shared primitive")
    }

    /// The full-screen decode budget: both arms request the 4 MP square
    /// ceiling (Android's slot × maxScale request collapses to it on every
    /// supported display; the bounded decoder has no sub-rect path).
    @Test func fullScreenDecodeBudgetIsTheFourMegapixelCeiling() throws {
        #expect(FullScreenDocumentView.fullScreenMaxPixelSize == 2048)
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI/FullScreenDocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let budgeted = text.components(
            separatedBy: "maxPixelSize: FullScreenDocumentView.fullScreenMaxPixelSize")
        #expect(budgeted.count == 3, "both arms must request the shared full-screen budget")
    }

    /// The caption is a SIBLING of the arm dispatch (Z.8): composed exactly
    /// once, at the dispatcher level, outside every arm struct.
    @Test func trustCaptionIsComposedOnceAtTheDispatcherLevel() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI/FullScreenDocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "DocumentTrustCaption()").count == 2)
        let dispatchIndex = try #require(text.range(of: "private struct"))
        let captionIndex = try #require(text.range(of: "DocumentTrustCaption()"))
        #expect(
            captionIndex.lowerBound < dispatchIndex.lowerBound,
            "the caption must sit in the dispatcher, before any private arm struct")
    }
}
