#if canImport(PDFKit)
import CoreGraphics
import Foundation
import Testing

@testable import PassesPDF

/// Regression for GitHub #92: `page.draw` composites onto the render buffer
/// without clearing it, so a PDF that relies on the implicit white page
/// background used to rasterise as content-on-transparent and compose against
/// the host's dark surface, hiding white-on-page artwork (QR codes vanished in
/// dark mode). `rasterise` now fills the bitmap white before drawing.
///
/// Deviation from Android, intentional: passes-android's counterpart
/// (`PdfRendererServiceInstrumentedTest.pageBackgroundRasterisesWhiteNotTransparent`)
/// is `@Ignore`d pending on-device CI + SharedMemory bitmap reconstruction. iOS
/// renders in-process, so the pixel assertion runs deterministically here.
struct PDFKitRendererWhiteBackgroundTests {
    /// A one-page PDF whose only content is a small black square in the centre;
    /// the rest of the page is the implicit (transparent-until-composited) PDF
    /// background.
    private func singlePagePDF(width: CGFloat, height: CGFloat) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: width / 2 - 5, y: height / 2 - 5, width: 10, height: 10))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    @Test func fullPageRasterisesOpaqueWhiteCorners() async {
        let pdf = singlePagePDF(width: 100, height: 100)
        let result = await PDFKitRenderer().render(
            pdf: pdf, page: 0, widthPx: 50, heightPx: 50, sourceRect: .fullPage
        )
        guard case .ok(let pixels, let widthPx, let heightPx, _) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        // RGBA premultiplied-last. Pre-fix the corners were transparent (0,0,0,0);
        // the implicit-white page background must now rasterise opaque white.
        let bytes = [UInt8](pixels)
        let bytesPerRow = widthPx * 4
        let topLeft = Array(bytes[0..<4])
        let bottomRightStart = (heightPx - 1) * bytesPerRow + (widthPx - 1) * 4
        let bottomRight = Array(bytes[bottomRightStart..<bottomRightStart + 4])
        #expect(topLeft == [255, 255, 255, 255])
        #expect(bottomRight == [255, 255, 255, 255])
    }
}
#endif
