import Foundation
import SwiftUI
import PassesPDF
import PassesPDFCore

/// Outcome of a thumbnail render. Drives consumer placeholder / image /
/// error chrome from a single closed set. The shape is narrow by design:
/// no field through which a consumer could surface PDF text, metadata, or
/// annotations. Mirror of Android's `PdfThumbnailState` sealed interface.
/// `PDFThumbnailSurfaceTests` locks the arms so a future contributor
/// cannot quietly add a payload-shaped field.
public enum PDFThumbnailState: Sendable {
    case loading
    case rendered(image: PageImageHandle, pageAspect: Float)
    case failed(kind: DocumentRejectedKind)
}

/// Wrapper around a decoded page bitmap. Carries a `SwiftUI.Image` for
/// drawing plus the source aspect ratio. The image is held by reference
/// (a `CGImage`) so passing the handle around does not copy pixels.
public struct PageImageHandle: Sendable {
    public let image: Image
    public let pageAspect: Float

    fileprivate init(pageImage: PageImage) {
        self.image = pageImage.image
        self.pageAspect = pageImage.pageAspect
    }
}

/// The cache's default size — how many recently-rendered pages to retain
/// per consumer. Sized so the page-pager in `DocumentView` can keep the
/// current page plus +/- 2 adjacent pages hot during a swipe without
/// recycling an image still being painted.
public let defaultPageWindow: Int = 5

/// Bounded RAM-bounded cache for page images produced by
/// ``PDFThumbnailViewModel``. Hoist a single instance to list scope so
/// every visible row shares a fixed cap. `clear()` is the only
/// public-mutation surface; the surface lock test pins this.
public final class PDFThumbnailCache: @unchecked Sendable {
    private let backing: RenderedPageCache<PageImage>
    private let lock = NSLock()

    public init(maxSize: Int = defaultPageWindow) {
        self.backing = RenderedPageCache<PageImage>(maxSize: maxSize)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        backing.clear()
    }

    func get(documentId: PDFDocumentId, page: Int) -> PageImage? {
        lock.lock()
        defer { lock.unlock() }
        return backing.get(documentId: documentId, page: page)
    }

    func put(documentId: PDFDocumentId, page: Int, value: PageImage) {
        lock.lock()
        defer { lock.unlock() }
        backing.put(documentId: documentId, page: page, value: value)
    }
}

/// SwiftUI-friendly facade over `PDFRendererBinder` for a single-page
/// thumbnail. The view model owns the render task lifetime so consuming
/// rows do not have to reimplement cancellation, cache discipline, or
/// telemetry routing. Mirror of Android's `rememberPdfThumbnail`
/// composable.
///
/// Trust posture (ADR 0005 D4 / D7 / D8): the view model exposes only
/// `state` — a ``PDFThumbnailState`` arm with no extraction-shaped fields.
/// `pdf` is borrowed for the duration of the view's existence; rendering
/// always passes through `PDFRendererBinder`, so the consumer can never
/// reach PDF text, metadata, or annotations through this surface.
@MainActor
@Observable
public final class PDFThumbnailViewModel {
    public private(set) var state: PDFThumbnailState = .loading

    private var renderTask: Task<Void, Never>?

    public init() {}

    /// Kick off a render. Cancelling any prior render in flight first so a
    /// rapid `start(...)` -> `start(...)` rebind does not retain two tasks.
    public func start(
        document: PDFDocument,
        pdfData: Data,
        renderer: PDFRendererBinder,
        page: Int,
        targetWidthPx: Int,
        targetHeightPx: Int,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        cache: PDFThumbnailCache? = nil
    ) {
        let documentId = document.id
        let widthPx = max(targetWidthPx, 1)
        let heightPx = max(targetHeightPx, 1)
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.run(
                documentId: documentId,
                pdfData: pdfData,
                renderer: renderer,
                page: page,
                widthPx: widthPx,
                heightPx: heightPx,
                telemetry: telemetry,
                cache: cache
            )
        }
    }

    /// Stop any in-flight render. Called by hosting views on disappearance
    /// so the task does not survive the view.
    public func stop() {
        renderTask?.cancel()
        renderTask = nil
    }

    private func run(
        documentId: PDFDocumentId,
        pdfData: Data,
        renderer: PDFRendererBinder,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        telemetry: DocumentTelemetryGuard,
        cache: PDFThumbnailCache?
    ) async {
        if let cached = cache?.get(documentId: documentId, page: page) {
            state = .rendered(
                image: PageImageHandle(pageImage: cached),
                pageAspect: cached.pageAspect
            )
            return
        }
        let result = await renderOrDiscard(
            renderer: renderer,
            pdf: pdfData,
            page: page,
            widthPx: widthPx,
            heightPx: heightPx,
            sourceRect: .fullPage,
            isStillWanted: { !Task.isCancelled }
        )
        guard let result else { return }
        switch result {
        case .rejected(let kind):
            state = .failed(kind: kind)
        case .ok:
            guard let ok = renderOkFrom(result) else {
                state = .failed(kind: .rendererFailed)
                return
            }
            let decoded = DecodedPage(
                pixels: ok.pixels,
                widthPx: ok.widthPx,
                heightPx: ok.heightPx,
                pageAspect: ok.pageAspect
            )
            guard let pageImage = decodePageImage(from: decoded) else {
                telemetry.onConsumerRenderFailed(reason: .dimensionMismatch)
                state = .failed(kind: .rendererFailed)
                return
            }
            cache?.put(documentId: documentId, page: page, value: pageImage)
            state = .rendered(
                image: PageImageHandle(pageImage: pageImage),
                pageAspect: pageImage.pageAspect
            )
        }
    }
}
