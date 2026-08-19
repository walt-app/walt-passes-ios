import Foundation
import PassesPDFCore

/// The renderer contract for `PassesPDF`. Mirrors Android's
/// `PdfRendererBinder` interface 1:1, minus the IPC framing — on iOS there is
/// no isolated-process binder and no AIDL: same-process PDFKit calls live
/// behind the same protocol so the importer's orchestration code is identical
/// to the Android shape and the same set of trust-claim tests can pin both.
///
/// Two methods, both load-bearing: ``probe(pdf:)`` returns the page count for
/// a candidate PDF (or a rejection enum), and ``render(pdf:page:widthPx:heightPx:sourceRect:)``
/// rasterises a single page (optionally a sub-rect of one) into a pixel
/// buffer. The deliberate absence of `getText`, `getMetadata`,
/// `getAnnotations`, `getAttachments`, and `getFormFields` is the trust
/// claim mirrored from ADR 0005 D4 (no extraction from PDF content).
public protocol PDFRendererBinder: Sendable {
    func probe(pdf: Data) async -> ProbeResult
    func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult

    /// Full-page render at aspect-correct dimensions fitted within `maxPixels`
    /// (width * height). Unlike ``render(pdf:page:widthPx:heightPx:sourceRect:)``, the
    /// output dimensions derive from the page's own geometry, so the raster is never
    /// stretched — the shape the import-time render-once pass (ios-dts.16) persists.
    func renderFitted(
        pdf: Data,
        page: Int,
        maxPixels: Int64
    ) async -> RenderResult

    /// Fitted renders for pages `0..<pageCount` in order, stopping at the first
    /// rejection (the returned array then ends with that rejection). Exists so an
    /// implementation can open the document ONCE for the whole import pass instead of
    /// re-parsing the untrusted bytes per page; the default loops ``renderFitted``.
    func renderAllFitted(
        pdf: Data,
        pageCount: Int,
        maxPixels: Int64
    ) async -> [RenderResult]
}

extension PDFRendererBinder {
    /// Fail-closed default so the ios-dts.16 additions are not source-breaking for
    /// out-of-package conformers: a binder that never learned to render fitted pages
    /// rejects them rather than failing to compile.
    public func renderFitted(
        pdf: Data,
        page: Int,
        maxPixels: Int64
    ) async -> RenderResult {
        .rejected(kind: .rendererFailed)
    }

    public func renderAllFitted(
        pdf: Data,
        pageCount: Int,
        maxPixels: Int64
    ) async -> [RenderResult] {
        var results: [RenderResult] = []
        results.reserveCapacity(max(pageCount, 0))
        for page in 0..<max(pageCount, 0) {
            let result = await renderFitted(pdf: pdf, page: page, maxPixels: maxPixels)
            results.append(result)
            if case .rejected = result { break }
        }
        return results
    }
}

/// Outcome of the page-count probe. Modelled with the same enum-based
/// rejection vocabulary as the rest of `PassesPDFCore` so a consumer can fold
/// probe and render rejections into a single `switch` over
/// ``PassesPDFCore/DocumentRejectedKind`` without a translation layer.
public enum ProbeResult: Sendable, Equatable {
    case ok(pageCount: Int)
    case rejected(kind: DocumentRejectedKind)
}

/// Outcome of a single-page render. The pixel layout in ``ok(pixels:widthPx:heightPx:pageAspect:)``
/// is ARGB-equivalent packed row-major with no padding; the receiver is
/// expected to reconstruct the bitmap via a `CGDataProvider` of the same
/// dimensions, mirroring Android's `Bitmap.copyPixelsFromBuffer` path.
public enum RenderResult: Sendable, Equatable {
    /// `pageAspect` is the page's natural width/height ratio; lets the UI
    /// compute where inside the destination bitmap the page content lives
    /// so zoom math can normalise against the page rect rather than the slot.
    case ok(pixels: Data, widthPx: Int, heightPx: Int, pageAspect: Float)
    case rejected(kind: DocumentRejectedKind)
}
