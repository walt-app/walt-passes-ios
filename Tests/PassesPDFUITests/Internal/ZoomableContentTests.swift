import Foundation
import PassesPDFCore
import SwiftUI
import Testing

@testable import PassesPDFUI

/// Pins the shared zoom primitive: the constants, the pan clamp and VoiceOver
/// zoom math, the clip by pixels (Android `ZoomableImageClipTest` analogue),
/// and the clip inventory: one scale site in the module, one slot-framed clip.
@MainActor
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

    @Test func voiceOverZoomStepsWithinTheRoster() {
        #expect(Zoom.accessibilityZoomed(1, zoomIn: true) == 2)
        #expect(Zoom.accessibilityZoomed(2.5, zoomIn: false) == 1.5)
        #expect(Zoom.accessibilityZoomed(5, zoomIn: true) == 5)
        #expect(Zoom.accessibilityZoomed(1.5, zoomIn: false) == 1)
    }

    /// Behavioral clip pin: content zoomed and panned toward the dock band must
    /// paint the whole slot (control) and none of the band below it.
    @Test func zoomedContentNeverPaintsTheDockBand() throws {
        let side = 40
        let band = 20
        let view = VStack(spacing: 0) {
            ZoomableContent(
                label: Text("Zoomed"), initialScale: 5, initialOffset: CGSize(width: 0, height: 30)
            ) {
                Color.red.padding(10)
            }
            .frame(width: CGFloat(side), height: CGFloat(side))
            Color.clear.frame(width: CGFloat(side), height: CGFloat(band))
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let red = try #require(Self.redMask(image))
        try #require(image.width == side && image.height == side + band)
        let slotRed = (0..<side).reduce(0) { sum, row in sum + red[row].filter { $0 }.count }
        let bandRed = (side..<(side + band)).reduce(0) { sum, row in sum + red[row].filter { $0 }.count }
        #expect(slotRed == side * side, "the zoomed content must fill the slot")
        #expect(bandRed == 0, "zoomed content painted outside its slot")
    }

    /// Row-major (top row first) map of strongly red, opaque pixels.
    private static func redMask(_ image: CGImage) -> [[Bool]]? {
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { row in
            (0..<width).map { col in
                let offset = (row * width + col) * 4
                return pixels[offset] > 200 && pixels[offset + 1] < 60 && pixels[offset + 3] > 200
            }
        }
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
