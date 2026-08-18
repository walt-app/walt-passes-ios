import Foundation
import PassesPDFCore

/// The ONE sanctioned fallback from the render-once contract (ios-dts.16): a
/// `DocumentPageSource` that serves stored rasters and, on a miss, performs a
/// single bounded re-render of the original bytes, persists the result, and
/// serves it. Misses are expected exactly twice in a document's life at most:
/// legacy documents imported before the raster table existed (v6), and the
/// rare lost blob. Steady state is store-hits only, so the untrusted bytes
/// meet a PDF parser once per document, at import — never per open.
///
/// Storage stays behind closures (`loadStored` / `persistRaster`) so
/// `PassesPDF` and `PassesStorage` remain independent peers; the consumer
/// (walt-app `DataPasses`) wires both to its repository. `loadOriginalBytes`
/// is deferred and only invoked on a miss — the common path never loads the
/// original blob at all.
///
/// A failed re-render returns `nil` (the display surface shows its failure
/// arm); it is NOT retried in a loop — each `pageRaster` call performs at
/// most one render. `persistRaster` failures are swallowed: the page still
/// displays this open, and the backfill retries on a future miss.
public struct RerenderOnMissPageSource: DocumentPageSource {
    private let loadStored: @Sendable (Int) async -> StoredPageRaster?
    private let loadOriginalBytes: @Sendable () async -> Data?
    private let renderer: any PDFRendererBinder
    private let encoder: any PageRasterEncoding
    private let persistRaster: @Sendable (Int, StoredPageRaster) async -> Void

    public init(
        loadStored: @escaping @Sendable (Int) async -> StoredPageRaster?,
        loadOriginalBytes: @escaping @Sendable () async -> Data?,
        renderer: any PDFRendererBinder,
        persistRaster: @escaping @Sendable (Int, StoredPageRaster) async -> Void
    ) {
        self.init(
            loadStored: loadStored,
            loadOriginalBytes: loadOriginalBytes,
            renderer: renderer,
            encoder: DefaultPageRasterEncoder(),
            persistRaster: persistRaster
        )
    }

    init(
        loadStored: @escaping @Sendable (Int) async -> StoredPageRaster?,
        loadOriginalBytes: @escaping @Sendable () async -> Data?,
        renderer: any PDFRendererBinder,
        encoder: any PageRasterEncoding,
        persistRaster: @escaping @Sendable (Int, StoredPageRaster) async -> Void
    ) {
        self.loadStored = loadStored
        self.loadOriginalBytes = loadOriginalBytes
        self.renderer = renderer
        self.encoder = encoder
        self.persistRaster = persistRaster
    }

    public func pageRaster(page: Int) async -> StoredPageRaster? {
        if let stored = await loadStored(page) {
            return stored
        }
        guard let bytes = await loadOriginalBytes() else { return nil }
        let result = await renderer.renderFitted(
            pdf: bytes,
            page: page,
            maxPixels: DefaultPDFImporter.pageRasterMaxPixels
        )
        guard case .ok(_, let widthPx, let heightPx, _) = result else { return nil }
        guard let pngBytes = try? encoder.encode(render: result) else { return nil }
        let raster = StoredPageRaster(pngBytes: pngBytes, widthPx: widthPx, heightPx: heightPx)
        await persistRaster(page, raster)
        return raster
    }
}

/// Internal encoder seam so tests can fake the PNG step without CoreGraphics.
/// Production delegates to the same `PNGThumbnailEncoder` the importer uses.
protocol PageRasterEncoding: Sendable {
    func encode(render: RenderResult) throws -> Data
}

struct DefaultPageRasterEncoder: PageRasterEncoding {
    #if canImport(ImageIO) && canImport(CoreGraphics)
    private let encoder = PNGThumbnailEncoder()
    func encode(render: RenderResult) throws -> Data {
        try encoder.encode(render: render)
    }
    #else
    func encode(render: RenderResult) throws -> Data {
        throw ThumbnailEncoderError("PNG encoding unavailable on this platform")
    }
    #endif
}
