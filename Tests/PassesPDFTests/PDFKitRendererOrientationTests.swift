#if canImport(PDFKit)
import CoreGraphics
import Foundation
import Testing

@testable import PassesPDF

/// Regression for ipass-auy: every page rasterised upside down because
/// `rasterise` y-flipped a `CGContext(data:)` bitmap that is already y-up.
/// A page whose only ink is a bar along its TOP edge must land at row 0 of
/// the returned buffer on every render path, including a `.subRect` whose
/// `top` is measured from the page top.
struct PDFKitRendererOrientationTests {
    private static let pageWidth: CGFloat = 200
    private static let pageHeight: CGFloat = 300
    private static let barHeight: CGFloat = 20

    /// One page, white implicit background, black bar across the top `barHeight` points.
    private func topBarPDF() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(
            CGRect(
                x: 0, y: Self.pageHeight - Self.barHeight,
                width: Self.pageWidth, height: Self.barHeight
            )
        )
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private struct Raster {
        let bytes: [UInt8]
        let widthPx: Int
        let heightPx: Int

        /// RGBA at the horizontal centre of `row`.
        func centrePixel(row: Int) -> [UInt8] {
            let start = row * widthPx * 4 + (widthPx / 2) * 4
            return Array(bytes[start..<start + 4])
        }

        var firstRow: [UInt8] { centrePixel(row: 0) }
        var lastRow: [UInt8] { centrePixel(row: heightPx - 1) }
    }

    private func raster(_ result: RenderResult) -> Raster? {
        guard case .ok(let pixels, let widthPx, let heightPx, _) = result else {
            Issue.record("expected .ok, got \(result)")
            return nil
        }
        return Raster(bytes: [UInt8](pixels), widthPx: widthPx, heightPx: heightPx)
    }

    private let black: [UInt8] = [0, 0, 0, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    @Test func fullPageKeepsTopOfPageAtRowZero() async {
        let result = await PDFKitRenderer().render(
            pdf: topBarPDF(), page: 0, widthPx: 100, heightPx: 150, sourceRect: .fullPage
        )
        guard let raster = raster(result) else { return }
        #expect(raster.firstRow == black)
        #expect(raster.lastRow == white)
    }

    @Test func renderFittedKeepsTopOfPageAtRowZero() async {
        let result = await PDFKitRenderer().renderFitted(
            pdf: topBarPDF(), page: 0, maxPixels: 100 * 150
        )
        guard let raster = raster(result) else { return }
        #expect(raster.firstRow == black)
        #expect(raster.lastRow == white)
    }

    @Test func subRectTopHalfKeepsTopOfPageAtRowZero() async {
        let result = await PDFKitRenderer().render(
            pdf: topBarPDF(), page: 0, widthPx: 100, heightPx: 75,
            sourceRect: .subRect(left: 0, top: 0, right: 1, bottom: 0.5)
        )
        guard let raster = raster(result) else { return }
        #expect(raster.firstRow == black)
        #expect(raster.lastRow == white)
    }

    @Test func subRectBottomHalfContainsNoTopBar() async {
        let result = await PDFKitRenderer().render(
            pdf: topBarPDF(), page: 0, widthPx: 100, heightPx: 75,
            sourceRect: .subRect(left: 0, top: 0.5, right: 1, bottom: 1)
        )
        guard let raster = raster(result) else { return }
        #expect(raster.firstRow == white)
        #expect(raster.lastRow == white)
    }
}
#endif
