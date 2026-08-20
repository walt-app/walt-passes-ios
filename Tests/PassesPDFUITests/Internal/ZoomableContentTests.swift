import Foundation
import PassesPDFCore
import SwiftUI
import Testing

@testable import PassesPDFUI

/// Pins the shared zoom primitive (ios-dts.12, wpass-pl7.4 mirror): the
/// constants, the pan clamp math, and the clip INVENTORY — Android's pixel
/// test (`ZoomableImageClipTest`) cannot run here, so the iOS pin is
/// structural and claims exactly what it checks: one scale site in the
/// module, in this file; one clip, framed to the slot before it clips.
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

    /// The clip inventory: every `scaleEffect` in this module lives in the
    /// shared primitive (a second site would escape its clip), and the
    /// primitive carries exactly ONE `.clipped()`, framed to the SLOT
    /// (`proxy.size`) immediately before it — the SwiftUI-true half of the
    /// wpass-pl7.4 clip lesson (a clip on a content-sized layer would follow
    /// the content; the slot frame is what makes the clip rect the slot).
    @Test func everyScaleSiteLivesInTheSharedPrimitive() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Internal
            .deletingLastPathComponent()  // PassesPDFUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/PassesPDFUI")
        let files = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scaleFiles: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.components(separatedBy: .newlines)
                .map { $0.components(separatedBy: "//").first ?? $0 }
                .joined(separator: "\n")
            if code.contains(".scaleEffect(") {
                scaleFiles.append(url.lastPathComponent)
            }
            if url.lastPathComponent == "ZoomableContent.swift" {
                #expect(
                    code.components(separatedBy: ".scaleEffect(").count == 2,
                    "one scale site — a second would escape the shared clip")
                let clips = code.components(separatedBy: ".clipped()")
                #expect(clips.count == 2, "exactly one clip — the slot-framed one")
                #expect(
                    clips.first?.contains(".frame(width: proxy.size.width") == true,
                    "the clip must be framed to the slot before it clips")
            }
        }
        #expect(scaleFiles == ["ZoomableContent.swift"], "zoom escaped the shared primitive")
    }

    /// The full-screen decode budget: both arms request the shared 2048-square
    /// box (at or under the decoder's 4 MP cap; see the constant's doc).
    @Test func fullScreenDecodeBudgetIsTheSharedCeiling() throws {
        #expect(FullScreenDocumentView.fullScreenMaxPixelSize == 2048)
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI/FullScreenDocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let budgeted = text.components(
            separatedBy: "maxPixelSize: FullScreenDocumentView.fullScreenMaxPixelSize")
        #expect(budgeted.count == 3, "both arms must request the shared full-screen budget")
    }
}
