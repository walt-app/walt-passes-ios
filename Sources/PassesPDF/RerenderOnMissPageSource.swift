import Foundation
import PassesPDFCore

/// The ONE sanctioned fallback from the render-once contract (ios-dts.16): a
/// `DocumentPageSource` that serves stored rasters and, on a miss, performs a
/// single bounded re-render of the original bytes, persists the result, and
/// serves it. Misses are expected exactly twice in a document's life at most:
/// legacy documents imported before the raster table existed (v6), and the
/// rare lost blob. Steady state is store-hits only, so the untrusted bytes
/// meet a PDF parser only at import (plus one bounded re-render per missed
/// page here), never on display.
///
/// Storage stays behind closures (`loadStored` / `persistRaster`) so
/// `PassesPDF` and `PassesStorage` remain independent peers; the consumer
/// (walt-app `DataPasses`) wires `persistRaster` to the per-page
/// `insertDocumentPageRaster` backfill (pre-v6 pages recover one open at a
/// time, so a full-set write can never be assembled here). `loadOriginalBytes`
/// is deferred and only invoked on a miss — the common path never loads the
/// original blob at all.
///
/// Miss work is COALESCED per page and SERIALIZED across pages: a pager that
/// starts adjacent legacy pages together performs one `PDFDocument` parse at
/// a time and never parses the same page twice concurrently. Both properties
/// are scoped to ONE initialised instance (copies share the worker;
/// re-initialisation does not) — hold a single source per document for the
/// lifetime of the surface; constructing one per SwiftUI `body` evaluation
/// silently defeats the coalescing. A failed
/// re-render returns `nil` (the display surface shows its failure arm) and is
/// reported through `telemetry.onConsumerRenderFailed`; it is NOT retried in
/// a loop — each miss performs at most one render. `persistRaster` failures
/// are swallowed: the page still displays this open, and the backfill retries
/// on a future miss.
public struct RerenderOnMissPageSource: DocumentPageSource {
    private let loadStored: @Sendable (Int) async -> StoredPageRaster?
    private let loadOriginalBytes: @Sendable () async -> Data?
    private let renderer: any PDFRendererBinder
    private let encoder: any PageRasterEncoding
    private let persistRaster: @Sendable (Int, StoredPageRaster) async -> Void
    private let telemetry: DocumentTelemetryGuard
    private let misses = MissWorker()

    public init(
        loadStored: @escaping @Sendable (Int) async -> StoredPageRaster?,
        loadOriginalBytes: @escaping @Sendable () async -> Data?,
        renderer: any PDFRendererBinder,
        persistRaster: @escaping @Sendable (Int, StoredPageRaster) async -> Void,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
    ) {
        self.init(
            loadStored: loadStored,
            loadOriginalBytes: loadOriginalBytes,
            renderer: renderer,
            encoder: DefaultPageRasterEncoder(),
            persistRaster: persistRaster,
            telemetry: telemetry
        )
    }

    init(
        loadStored: @escaping @Sendable (Int) async -> StoredPageRaster?,
        loadOriginalBytes: @escaping @Sendable () async -> Data?,
        renderer: any PDFRendererBinder,
        encoder: any PageRasterEncoding,
        persistRaster: @escaping @Sendable (Int, StoredPageRaster) async -> Void,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
    ) {
        self.loadStored = loadStored
        self.loadOriginalBytes = loadOriginalBytes
        self.renderer = renderer
        self.encoder = encoder
        self.persistRaster = persistRaster
        self.telemetry = telemetry
    }

    public func pageRaster(page: Int) async -> StoredPageRaster? {
        if let stored = await loadStored(page) {
            return stored
        }
        let loadOriginalBytes = self.loadOriginalBytes
        let renderer = self.renderer
        let encoder = self.encoder
        let persistRaster = self.persistRaster
        let telemetry = self.telemetry
        return await misses.raster(page: page) {
            guard let bytes = await loadOriginalBytes() else { return nil }
            let result = await renderer.renderFitted(
                pdf: bytes,
                page: page,
                maxPixels: DefaultPDFImporter.pageRasterMaxPixels
            )
            guard case .ok(_, let widthPx, let heightPx, _) = result else {
                telemetry.onConsumerRenderFailed(reason: .other)
                return nil
            }
            guard let pngBytes = try? encoder.encode(render: result) else {
                telemetry.onConsumerRenderFailed(reason: .other)
                return nil
            }
            let raster = StoredPageRaster(pngBytes: pngBytes, widthPx: widthPx, heightPx: heightPx)
            await persistRaster(page, raster)
            return raster
        }
    }
}

/// Dedupes concurrent misses of the same page and serializes miss work across
/// pages, so at most ONE re-render of the untrusted originals runs at a time
/// per source instance. Actor reentrancy cannot interleave the renders: each
/// task first awaits the previous chain link, and the chain is extended
/// inside the actor before anything suspends.
private actor MissWorker {
    private var inFlight: [Int: Task<StoredPageRaster?, Never>] = [:]
    private var chainTail: Task<Void, Never>?

    func raster(
        page: Int,
        work: @escaping @Sendable () async -> StoredPageRaster?
    ) async -> StoredPageRaster? {
        if let existing = inFlight[page] {
            return await existing.value
        }
        let previous = chainTail
        let task = Task<StoredPageRaster?, Never> {
            await previous?.value
            return await work()
        }
        inFlight[page] = task
        chainTail = Task { _ = await task.value }
        let result = await task.value
        inFlight[page] = nil
        return result
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
