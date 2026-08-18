#if canImport(PDFKit)
import Foundation
import CoreGraphics
import PDFKit
import PassesPDFCore

/// PDFKit-backed implementation of ``PDFRendererBinder``. The iOS analogue of
/// Android's `PdfRendererService` + `doProbe` / `doRender`. PDFKit replaces
/// `android.graphics.pdf.PdfRenderer`; CoreGraphics replaces the
/// `Bitmap` -> `SharedMemory` pixel pipeline.
///
/// This implementation is intentionally not exercised by the unit suite: the
/// trust-claim-bearing orchestration lives in ``DefaultPDFImporter``, which
/// fakes ``PDFRendererBinder`` in tests so the test surface stays free of
/// PDFKit's IO surface. The behaviour pinned here mirrors the Android side:
///
///  - Page-count probe enforces `maxPages` and folds open failures onto a
///    rejection kind.
///  - Render dimensions and source-rect are validated before any draw call.
///  - Encrypted PDFs are rejected as ``PassesPDFCore/DocumentRejectedKind/encrypted``.
package struct PDFKitRenderer: PDFRendererBinder {
    /// Bound on render output dimensions. 4 MP at 4 bytes/pixel is 16 MB of
    /// pixel data, comfortably below what `CGContext` allocates on iOS. The
    /// cap is a defence against a malicious caller asking for an arbitrarily
    /// large bitmap; the design expectation is that the UI layer renders at
    /// view-port resolution and never approaches this number. Mirrors
    /// Android's `PdfRendererService.MAX_PIXELS`.
    package static let maxPixels: Int64 = 4 * 1024 * 1024

    private let maxPages: Int

    package init(maxPages: Int = PDFImportConfig.defaultMaxPages) {
        self.maxPages = maxPages
    }

    package func probe(pdf: Data) async -> ProbeResult {
        guard let doc = PDFDocument(data: pdf) else {
            return .rejected(kind: .notAPdf)
        }
        if doc.isEncrypted, doc.isLocked {
            return .rejected(kind: .encrypted)
        }
        let pages = doc.pageCount
        if pages > maxPages {
            return .rejected(kind: .tooManyPages)
        }
        return .ok(pageCount: pages)
    }

    package func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult {
        let dimsOk =
            widthPx > 0
            && heightPx > 0
            && Int64(widthPx) * Int64(heightPx) <= Self.maxPixels
        let rectOk = isSourceRectValid(sourceRect)
        guard dimsOk, rectOk else {
            return .rejected(kind: .rendererFailed)
        }
        guard let doc = PDFDocument(data: pdf) else {
            return .rejected(kind: .notAPdf)
        }
        if doc.isEncrypted, doc.isLocked {
            return .rejected(kind: .encrypted)
        }
        guard page >= 0, page < doc.pageCount, page < maxPages else {
            return .rejected(kind: .rendererFailed)
        }
        guard let pdfPage = doc.page(at: page) else {
            return .rejected(kind: .rendererFailed)
        }
        return rasterise(
            page: pdfPage,
            widthPx: widthPx,
            heightPx: heightPx,
            sourceRect: sourceRect
        )
    }

    package func renderFitted(
        pdf: Data,
        page: Int,
        maxPixels: Int64
    ) async -> RenderResult {
        guard maxPixels > 0, maxPixels <= Self.maxPixels else {
            return .rejected(kind: .rendererFailed)
        }
        guard let doc = PDFDocument(data: pdf) else {
            return .rejected(kind: .notAPdf)
        }
        if doc.isEncrypted, doc.isLocked {
            return .rejected(kind: .encrypted)
        }
        guard page >= 0, page < doc.pageCount, page < maxPages else {
            return .rejected(kind: .rendererFailed)
        }
        guard let pdfPage = doc.page(at: page) else {
            return .rejected(kind: .rendererFailed)
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return .rejected(kind: .rendererFailed)
        }
        let dims = Self.fittedDimensions(
            pageWidth: Double(bounds.width),
            pageHeight: Double(bounds.height),
            maxPixels: maxPixels
        )
        return rasterise(
            page: pdfPage,
            widthPx: dims.widthPx,
            heightPx: dims.heightPx,
            sourceRect: .fullPage
        )
    }

    /// Aspect-correct output dimensions filling `maxPixels` as closely as possible without
    /// exceeding it. Pure so the fit math is testable without PDFKit; floors guarantee the
    /// product never exceeds the budget, and each side is at least 1.
    package static func fittedDimensions(
        pageWidth: Double,
        pageHeight: Double,
        maxPixels: Int64
    ) -> (widthPx: Int, heightPx: Int) {
        let aspect = pageWidth / pageHeight
        let height = (Double(maxPixels) / aspect).squareRoot()
        let width = height * aspect
        var w = max(Int(width), 1)
        var h = max(Int(height), 1)
        // Flooring both sides already keeps w*h <= maxPixels for any real page shape;
        // the loop is a belt for degenerate aspects where a side floored to 1.
        while Int64(w) * Int64(h) > maxPixels {
            if w >= h { w = max(w - 1, 1) } else { h = max(h - 1, 1) }
        }
        return (w, h)
    }

    private func rasterise(
        page: PDFPage,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) -> RenderResult {
        let pageBounds = page.bounds(for: .mediaBox)
        let pageW = Float(pageBounds.width)
        let pageH = Float(pageBounds.height)
        let pageAspect: Float = pageH > 0 ? pageW / pageH : 1
        let bytesPerPixel = 4
        let bytesPerRow = widthPx * bytesPerPixel
        var pixels = Data(count: bytesPerRow * heightPx)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
            guard
                let ctx = CGContext(
                    data: base,
                    width: widthPx,
                    height: heightPx,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }
            // page.draw composites onto the zeroed (transparent) buffer without clearing;
            // fill white first so implicit-white pages don't show through dark UI (GH#92).
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
            // PDFKit draws in PDF coordinate space (origin bottom-left).
            // The bitmap is top-left, so flip y to match the Android
            // Bitmap layout consumers expect.
            ctx.translateBy(x: 0, y: CGFloat(heightPx))
            ctx.scaleBy(x: 1, y: -1)
            switch sourceRect {
            case .fullPage:
                ctx.scaleBy(
                    x: CGFloat(widthPx) / pageBounds.width,
                    y: CGFloat(heightPx) / pageBounds.height
                )
            case .subRect(let left, let top, let right, let bottom):
                let srcLeft = CGFloat(left) * pageBounds.width
                let srcTop = CGFloat(top) * pageBounds.height
                let srcW = CGFloat(right - left) * pageBounds.width
                let srcH = CGFloat(bottom - top) * pageBounds.height
                ctx.scaleBy(
                    x: CGFloat(widthPx) / srcW,
                    y: CGFloat(heightPx) / srcH
                )
                ctx.translateBy(x: -srcLeft, y: -srcTop)
            }
            page.draw(with: .mediaBox, to: ctx)
            return true
        }
        guard success else {
            return .rejected(kind: .rendererFailed)
        }
        return .ok(
            pixels: pixels,
            widthPx: widthPx,
            heightPx: heightPx,
            pageAspect: pageAspect
        )
    }
}
#endif
