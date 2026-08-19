import Foundation
import PassesPDFCore
import SwiftUI

/// Outcome of a page load. Drives consumer placeholder / image /
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

/// The cache's default size — how many recently-decoded pages to retain
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

/// The collaborators a page load runs against: the telemetry guard decode
/// failures are reported to, and the optional cache it reads from / writes
/// to. Since ios-dts.16 (render-once) there is NO renderer here — this
/// module cannot reach a PDF parser; pixels come exclusively from a
/// ``PassesPDFCore/DocumentPageSource`` of stored Walt-produced rasters.
public struct ThumbnailRenderContext: Sendable {
    public let telemetry: DocumentTelemetryGuard
    public let cache: PDFThumbnailCache?

    public init(
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        cache: PDFThumbnailCache? = nil
    ) {
        self.telemetry = telemetry
        self.cache = cache
    }
}

/// SwiftUI-friendly facade over a ``PassesPDFCore/DocumentPageSource`` for a
/// single page. The view model owns the load-task lifetime so consuming
/// rows do not have to reimplement cancellation, cache discipline, or
/// telemetry routing. Mirror of Android's `rememberPdfThumbnail`
/// composable, reshaped by ios-dts.16: it loads a stored first-party
/// raster instead of driving a renderer.
///
/// Trust posture (ADR 0005 D4 / D7 / D8 + ios-dts.16): the view model
/// exposes only `state` — a ``PDFThumbnailState`` arm with no
/// extraction-shaped fields — and consumes only Walt-produced raster bytes.
/// The original document bytes are unreachable from this module.
@MainActor
@Observable
public final class PDFThumbnailViewModel {
    public private(set) var state: PDFThumbnailState = .loading

    private var loadTask: Task<Void, Never>?

    public init() {}

    /// Kick off a page load. Cancelling any prior load in flight first so a
    /// rapid `start(...)` -> `start(...)` rebind does not retain two tasks.
    /// `maxPixelSize` caps the decoded bitmap's longer side (see
    /// `decodeStoredRaster`); `nil` decodes the stored raster at full size.
    public func start(
        document: PDFDocument, page: Int, source: any DocumentPageSource,
        context: ThumbnailRenderContext, maxPixelSize: Int? = nil
    ) {
        let documentId = document.id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.run(
                documentId: documentId, page: page, source: source,
                context: context, maxPixelSize: maxPixelSize
            )
        }
    }

    /// Stop any in-flight load. Called by hosting views on disappearance
    /// so the task does not survive the view.
    public func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func run(
        documentId: PDFDocumentId, page: Int, source: any DocumentPageSource,
        context: ThumbnailRenderContext, maxPixelSize: Int?
    ) async {
        if let cached = context.cache?.get(documentId: documentId, page: page) {
            state = .rendered(
                image: PageImageHandle(pageImage: cached),
                pageAspect: cached.pageAspect
            )
            return
        }
        let raster = await source.pageRaster(page: page)
        guard !Task.isCancelled else { return }
        guard let raster else {
            state = .failed(kind: .rendererFailed)
            return
        }
        // The PNG inflate is synchronous CPU work; hop it off the main actor (the
        // renderer call this path replaced also ran on the cooperative pool) so a
        // pager swipe never stalls the UI on a page decode.
        let decoded = await Task.detached(priority: .userInitiated) {
            decodeStoredRaster(raster, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        guard let pageImage = decoded else {
            context.telemetry.onConsumerRenderFailed(reason: .other)
            state = .failed(kind: .rendererFailed)
            return
        }
        context.cache?.put(documentId: documentId, page: page, value: pageImage)
        state = .rendered(
            image: PageImageHandle(pageImage: pageImage),
            pageAspect: pageImage.pageAspect
        )
    }
}
