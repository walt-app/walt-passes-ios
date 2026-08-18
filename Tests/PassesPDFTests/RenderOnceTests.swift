import Foundation
import PassesPDFCore
import Testing

@testable import PassesPDF

/// Behavioral coverage for the ios-dts.16 render-once pass: the importer
/// rasterises EVERY page at import and hands the complete set to `persist`;
/// any page failing rejects the whole import; and the one sanctioned
/// fallback (`RerenderOnMissPageSource`) re-renders at most once per call,
/// only on a store miss.
@Suite("Render-once")
struct RenderOnceTests {

    private static func okRender(w: Int = 10, h: Int = 14) -> RenderResult {
        .ok(pixels: Data(repeating: 0, count: w * h * 4), widthPx: w, heightPx: h, pageAspect: 0.7)
    }

    // MARK: - Importer renders every page

    @Test func importPersistsOneRasterPerPage() async throws {
        let binder = StaticBinder(
            probeResult: .ok(pageCount: 3),
            renderResult: Self.okRender()
        )
        let importer = makeTestImporter(sessionFactory: RecordingSessionFactory(binder: binder))
        let recorder = RasterRecorder()
        let result = try await importer.import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "Doc",
            persist: { _, _, pages, _, rasters in
                recorder.record(pages: pages, rasters: rasters)
            }
        )
        guard case .imported = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let recorded = recorder.snapshot
        #expect(recorded?.pages == 3)
        #expect(recorded?.rasters.count == 3)
        // Dims travel from the fitted render result, not from any caller input.
        #expect(recorded?.rasters.first?.widthPx == 10)
        #expect(recorded?.rasters.first?.heightPx == 14)
    }

    @Test func fittedRenderRejectionOnAnyPageRejectsTheWholeImport() async throws {
        // Page 0 thumbnail render succeeds; the fitted pass fails on page 2 of 3.
        let binder = PageFailingBinder(
            probeResult: .ok(pageCount: 3),
            renderResult: Self.okRender(),
            failFittedAtPage: 2
        )
        let importer = makeTestImporter(sessionFactory: RecordingSessionFactory(binder: binder))
        let result = try await importer.import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "Doc",
            persist: { _, _, _, _, _ in
                Issue.record("persist must not run when a page raster fails")
            }
        )
        #expect(result == .rejected(kind: .rendererFailed))
    }

    @Test func encoderFailureOnRasterPassRejectsAsEncoderFailed() async throws {
        let binder = StaticBinder(
            probeResult: .ok(pageCount: 2),
            renderResult: Self.okRender()
        )
        // Encoder succeeds once (the page-0 thumbnail), then throws on the
        // raster pass, so the failure is attributable to the raster leg.
        let importer = makeTestImporter(
            sessionFactory: RecordingSessionFactory(binder: binder),
            thumbnailEncoder: FailAfterFirstEncoder()
        )
        let result = try await importer.import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "Doc",
            persist: { _, _, _, _, _ in
                Issue.record("persist must not run on raster encode failure")
            }
        )
        #expect(result == .rejected(kind: .encoderFailed))
    }

    // MARK: - Fitted dimension math

    #if canImport(PDFKit)
    @Test func fittedDimensionsPreserveAspectWithinBudget() {
        // A4 portrait: 595 x 842 pt. The fit fills the 4 MP budget without
        // exceeding it, and the aspect survives to within a pixel of rounding.
        let dims = PDFKitRenderer.fittedDimensions(
            pageWidth: 595, pageHeight: 842, maxPixels: 4 * 1024 * 1024
        )
        #expect(Int64(dims.widthPx) * Int64(dims.heightPx) <= 4 * 1024 * 1024)
        let aspect = Double(dims.widthPx) / Double(dims.heightPx)
        #expect(abs(aspect - 595.0 / 842.0) < 0.01)
        // Fills at least 99% of the budget (floors cost at most a row/column).
        #expect(Int64(dims.widthPx) * Int64(dims.heightPx) > 4 * 1024 * 1024 * 99 / 100)
    }

    @Test func fittedDimensionsDegenerateAspectStaysLegalAndBounded() {
        let dims = PDFKitRenderer.fittedDimensions(
            pageWidth: 10_000, pageHeight: 1, maxPixels: 1024
        )
        #expect(dims.widthPx >= 1 && dims.heightPx >= 1)
        #expect(Int64(dims.widthPx) * Int64(dims.heightPx) <= 1024)
    }
    #endif

    // MARK: - RerenderOnMissPageSource

    @Test func storeHitServesWithoutTouchingOriginals() async {
        let stored = StoredPageRaster(pngBytes: Data([0x01]), widthPx: 5, heightPx: 5)
        let counters = Counters()
        let source = RerenderOnMissPageSource(
            loadStored: { _ in stored },
            loadOriginalBytes: {
                counters.bump("originals")
                return TestFixtures.validPDFBytes
            },
            renderer: CountingBinder(counters: counters, result: Self.okRender()),
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in counters.bump("persist") }
        )
        let raster = await source.pageRaster(page: 0)
        #expect(raster == stored)
        #expect(counters.count("originals") == 0)
        #expect(counters.count("render") == 0)
        #expect(counters.count("persist") == 0)
    }

    @Test func storeMissRendersOncePersistsAndServes() async {
        let counters = Counters()
        let source = RerenderOnMissPageSource(
            loadStored: { _ in nil },
            loadOriginalBytes: {
                counters.bump("originals")
                return TestFixtures.validPDFBytes
            },
            renderer: CountingBinder(counters: counters, result: Self.okRender()),
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in counters.bump("persist") }
        )
        let raster = await source.pageRaster(page: 1)
        #expect(raster?.widthPx == 10)
        #expect(raster?.heightPx == 14)
        #expect(counters.count("originals") == 1)
        #expect(counters.count("render") == 1)
        #expect(counters.count("persist") == 1)
    }

    @Test func failedRerenderReturnsNilAndPersistsNothing() async {
        let counters = Counters()
        let source = RerenderOnMissPageSource(
            loadStored: { _ in nil },
            loadOriginalBytes: { TestFixtures.validPDFBytes },
            renderer: CountingBinder(counters: counters, result: .rejected(kind: .rendererFailed)),
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in counters.bump("persist") }
        )
        let raster = await source.pageRaster(page: 0)
        #expect(raster == nil)
        // Exactly one render attempt per call, no retry loop, nothing persisted.
        #expect(counters.count("render") == 1)
        #expect(counters.count("persist") == 0)
    }
}

// MARK: - Local test doubles

private final class RasterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _recorded: (pages: Int, rasters: [StoredPageRaster])?

    func record(pages: Int, rasters: [StoredPageRaster]) {
        syncLocked(lock) { _recorded = (pages, rasters) }
    }

    var snapshot: (pages: Int, rasters: [StoredPageRaster])? {
        syncLocked(lock) { _recorded }
    }
}

private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func bump(_ key: String) {
        syncLocked(lock) { counts[key, default: 0] += 1 }
    }

    func count(_ key: String) -> Int {
        syncLocked(lock) { counts[key] ?? 0 }
    }
}

/// Succeeds everywhere except the fitted render of one page index.
private struct PageFailingBinder: PDFRendererBinder {
    let probeResult: ProbeResult
    let renderResult: RenderResult
    let failFittedAtPage: Int

    func probe(pdf: Data) async -> ProbeResult { probeResult }

    func render(
        pdf: Data, page: Int, widthPx: Int, heightPx: Int, sourceRect: RenderSourceRect
    ) async -> RenderResult {
        renderResult
    }

    func renderFitted(pdf: Data, page: Int, maxPixels: Int64) async -> RenderResult {
        page == failFittedAtPage ? .rejected(kind: .rendererFailed) : renderResult
    }
}

/// Counts fitted-render calls through the shared `Counters`.
private struct CountingBinder: PDFRendererBinder {
    let counters: Counters
    let result: RenderResult

    func probe(pdf: Data) async -> ProbeResult { .rejected(kind: .rendererFailed) }

    func render(
        pdf: Data, page: Int, widthPx: Int, heightPx: Int, sourceRect: RenderSourceRect
    ) async -> RenderResult {
        counters.bump("render")
        return result
    }

    func renderFitted(pdf: Data, page: Int, maxPixels: Int64) async -> RenderResult {
        counters.bump("render")
        return result
    }
}

private struct StubRasterEncoder: PageRasterEncoding {
    func encode(render: RenderResult) throws -> Data { Data([0x89, 0x50, 0x4E, 0x47]) }
}

/// First `encode` succeeds (the page-zero thumbnail), later calls throw —
/// isolates the raster-pass encode failure arm.
private final class FailAfterFirstEncoder: ThumbnailEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func encode(render: RenderResult) throws -> Data {
        let call = syncLocked(lock) { () -> Int in
            calls += 1
            return calls
        }
        if call > 1 { throw NSError(domain: "test", code: -1) }
        return Data([0x89, 0x50, 0x4E, 0x47])
    }
}
