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

    @Test func importUsesTheBatchEntryPointOncePerImport() async throws {
        let binder = BatchRecordingBinder(
            probeResult: .ok(pageCount: 3), result: Self.okRender(), rejectAtPage: nil
        )
        let importer = makeTestImporter(sessionFactory: RecordingSessionFactory(binder: binder))
        let result = try await importer.import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "Doc",
            persist: { _, _, _, _, _ in }
        )
        guard case .imported = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        // The one-parse claim: exactly one batch call carrying the probe's page count
        // and the import budget, and NO per-page fitted calls from the importer.
        #expect(binder.batchCalls.count == 1)
        #expect(binder.batchCalls.first?.pageCount == 3)
        #expect(binder.batchCalls.first?.maxPixels == DefaultPDFImporter.pageRasterMaxPixels)
        #expect(binder.perPageFittedCalls == 0)
    }

    @Test func batchRejectionMidStreamSurvivesToImportResult() async throws {
        let binder = BatchRecordingBinder(
            probeResult: .ok(pageCount: 3), result: Self.okRender(), rejectAtPage: 1
        )
        let importer = makeTestImporter(sessionFactory: RecordingSessionFactory(binder: binder))
        let result = try await importer.import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "Doc",
            persist: { _, _, _, _, _ in
                Issue.record("persist must not run when the batch rejects mid-stream")
            }
        )
        // The delivered rejection kind is what the import reports, not a generic fold.
        #expect(result == .rejected(kind: .encrypted))
    }

    @Test func pageRasterBudgetMatchesRendererCap() {
        // The literals are deliberately duplicated (PDFKitRenderer sits behind
        // canImport(PDFKit)); this pin turns a one-sided edit — which would fail
        // closed as "every import rejected" — into a loud test failure instead.
        #expect(DefaultPDFImporter.pageRasterMaxPixels == 4 * 1024 * 1024)
        #if canImport(PDFKit)
        #expect(DefaultPDFImporter.pageRasterMaxPixels == PDFKitRenderer.maxPixels)
        #endif
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

    /// Hostile mediaBox geometry (the review-1 blocker): extreme aspects must cost O(1)
    /// and never trap the `Int` conversion — these inputs previously drove a ~6.5e9
    /// iteration loop and a fatal-error conversion respectively.
    @Test func fittedDimensionsSurvivesHostileGeometry() {
        let budget: Int64 = 4 * 1024 * 1024
        for (w, h): (Double, Double) in [
            (1_000_000_000, 0.000_1),  // former per-pixel-walk shape
            (1_000_000_000, 0.000_001),  // former Int-conversion trap shape
            (0.000_001, 1_000_000_000),
            (Double.greatestFiniteMagnitude, 1),
            (1, Double.greatestFiniteMagnitude),
        ] {
            let dims = PDFKitRenderer.fittedDimensions(pageWidth: w, pageHeight: h, maxPixels: budget)
            #expect(dims.widthPx >= 1 && dims.heightPx >= 1)
            #expect(Int64(dims.widthPx) * Int64(dims.heightPx) <= budget)
        }
        // Non-finite aspect folds to the 1x1 floor rather than propagating NaN.
        let nan = PDFKitRenderer.fittedDimensions(
            pageWidth: .infinity, pageHeight: .infinity, maxPixels: budget
        )
        #expect(nan.widthPx == 1 && nan.heightPx == 1)
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

    @Test func failedRerenderReturnsNilPersistsNothingAndReportsTelemetry() async {
        let counters = Counters()
        let telemetry = ConsumerFailureRecordingTelemetry()
        let source = RerenderOnMissPageSource(
            loadStored: { _ in nil },
            loadOriginalBytes: { TestFixtures.validPDFBytes },
            renderer: CountingBinder(counters: counters, result: .rejected(kind: .rendererFailed)),
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in counters.bump("persist") },
            telemetry: telemetry
        )
        let raster = await source.pageRaster(page: 0)
        #expect(raster == nil)
        // Exactly one render attempt per call, no retry loop, nothing persisted —
        // and the failure is visible to telemetry rather than silent.
        #expect(counters.count("render") == 1)
        #expect(counters.count("persist") == 0)
        #expect(telemetry.consumerFailures == 1)
    }

    @Test func concurrentMissesOfTheSamePageRenderOnce() async {
        let counters = Counters()
        let gate = SlowBinder(counters: counters, result: Self.okRender())
        let source = RerenderOnMissPageSource(
            loadStored: { _ in nil },
            loadOriginalBytes: { TestFixtures.validPDFBytes },
            renderer: gate,
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in }
        )
        // Two concurrent requests for the same page must coalesce onto one render.
        async let first = source.pageRaster(page: 0)
        async let second = source.pageRaster(page: 0)
        let results = await [first, second]
        #expect(results.compactMap { $0 }.count == 2)
        #expect(counters.count("render") == 1)
    }

    @Test func concurrentMissesOfDifferentPagesSerializeTheParses() async {
        let counters = Counters()
        let gate = SlowBinder(counters: counters, result: Self.okRender())
        let source = RerenderOnMissPageSource(
            loadStored: { _ in nil },
            loadOriginalBytes: { TestFixtures.validPDFBytes },
            renderer: gate,
            encoder: StubRasterEncoder(),
            persistRaster: { _, _ in }
        )
        // Adjacent pager pages miss together: both render, but never concurrently —
        // SlowBinder records the peak number of in-flight renders.
        async let first = source.pageRaster(page: 0)
        async let second = source.pageRaster(page: 1)
        _ = await [first, second]
        #expect(counters.count("render") == 2)
        #expect(gate.peakConcurrency == 1)
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

/// Implements the streaming batch itself so tests can pin that the importer uses
/// it (and never the per-page path): records each batch call's shape and streams
/// `result` per page, optionally rejecting `.encrypted` at `rejectAtPage`.
private final class BatchRecordingBinder: PDFRendererBinder, @unchecked Sendable {
    struct BatchCall {
        let pageCount: Int
        let maxPixels: Int64
    }

    private let lock = NSLock()
    private let probeResult: ProbeResult
    private let result: RenderResult
    private let rejectAtPage: Int?
    private var _batchCalls: [BatchCall] = []
    private var _perPageFittedCalls = 0

    init(probeResult: ProbeResult, result: RenderResult, rejectAtPage: Int?) {
        self.probeResult = probeResult
        self.result = result
        self.rejectAtPage = rejectAtPage
    }

    var batchCalls: [BatchCall] {
        syncLocked(lock) { _batchCalls }
    }

    var perPageFittedCalls: Int {
        syncLocked(lock) { _perPageFittedCalls }
    }

    func probe(pdf: Data) async -> ProbeResult { probeResult }

    func render(
        pdf: Data, page: Int, widthPx: Int, heightPx: Int, sourceRect: RenderSourceRect
    ) async -> RenderResult {
        result
    }

    func renderFitted(pdf: Data, page: Int, maxPixels: Int64) async -> RenderResult {
        syncLocked(lock) { _perPageFittedCalls += 1 }
        return result
    }

    func renderAllFitted(
        pdf: Data,
        pageCount: Int,
        maxPixels: Int64,
        onPage: @Sendable (Int, RenderResult) -> Bool
    ) async {
        syncLocked(lock) { _batchCalls.append(BatchCall(pageCount: pageCount, maxPixels: maxPixels)) }
        for page in 0..<pageCount {
            let delivered: RenderResult = page == rejectAtPage ? .rejected(kind: .encrypted) : result
            let wantsMore = onPage(page, delivered)
            if case .rejected = delivered { return }
            if !wantsMore { return }
        }
    }
}

/// Fitted renders take a beat and record how many run at once, so the
/// serialization claim is observable rather than assumed.
private final class SlowBinder: PDFRendererBinder, @unchecked Sendable {
    private let lock = NSLock()
    private let counters: Counters
    private let result: RenderResult
    private var inFlight = 0
    private var _peak = 0

    init(counters: Counters, result: RenderResult) {
        self.counters = counters
        self.result = result
    }

    var peakConcurrency: Int {
        syncLocked(lock) { _peak }
    }

    func probe(pdf: Data) async -> ProbeResult { .rejected(kind: .rendererFailed) }

    func render(
        pdf: Data, page: Int, widthPx: Int, heightPx: Int, sourceRect: RenderSourceRect
    ) async -> RenderResult {
        result
    }

    func renderFitted(pdf: Data, page: Int, maxPixels: Int64) async -> RenderResult {
        counters.bump("render")
        syncLocked(lock) {
            inFlight += 1
            _peak = max(_peak, inFlight)
        }
        try? await Task.sleep(for: .milliseconds(20))
        syncLocked(lock) { inFlight -= 1 }
        return result
    }
}

/// Counts `onConsumerRenderFailed` calls from the self-heal failure arm.
private final class ConsumerFailureRecordingTelemetry: DocumentTelemetryGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var _consumerFailures = 0

    var consumerFailures: Int {
        syncLocked(lock) { _consumerFailures }
    }

    func onImportStarted() {}
    func onImportSucceeded(event: DocumentImportSucceededEvent) {}
    func onImportFailed(event: DocumentImportFailedEvent) {}
    func onConsumerRenderFailed(reason: ConsumerRenderFailure) {
        syncLocked(lock) { _consumerFailures += 1 }
    }
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
