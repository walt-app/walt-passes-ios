import Foundation
import PassesPDFCore

@testable import PassesPDF

/// Tiny mutex helper. `NSLock.lock()` is annotated `unavailable from
/// asynchronous contexts` under Swift 6; wrapping the lock/unlock pair in a
/// non-async function bypasses that diagnostic and is functionally
/// equivalent — the critical section is still synchronous, the lock just
/// happens to be held by code that the caller awaits.
func syncLocked<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// Minimum legal PDF header. The body after the magic is irrelevant to the
/// unit suite — the renderer is faked, so no decoder ever parses it.
enum TestFixtures {
    static let validPDFBytes: Data = Data("%PDF-1.4\n%¥±ë\n1 0 obj".utf8)

    static let defaultThumbW: Int = DefaultPDFImporter.thumbWidthPx
    static let defaultThumbH: Int = DefaultPDFImporter.thumbHeightPx

    /// 600 x 800 RGBA → 1 920 000 bytes. Matches the importer's THUMB
    /// constants. The fake renderer returns a buffer of this size on the
    /// happy path.
    static let defaultThumbPixelBytes: Int = defaultThumbW * defaultThumbH * 4

    /// Allocates a zeroed pixel buffer of `defaultThumbPixelBytes` for fake
    /// renderers that return a `.ok` result. The encoder seam never decodes
    /// it in the unit suite.
    static func defaultThumbPixelBuffer() -> Data {
        Data(repeating: 0, count: defaultThumbPixelBytes)
    }
}

// MARK: - Test doubles

final class RecordingSessionFactory: RendererSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connectCalls = 0
    private var _lastSession: RecordingSession?
    let binder: any PDFRendererBinder

    init(binder: any PDFRendererBinder = StaticBinder()) {
        self.binder = binder
    }

    var connectCalls: Int {
        syncLocked(lock) { _connectCalls }
    }

    var lastSession: RecordingSession? {
        syncLocked(lock) { _lastSession }
    }

    func connect() async -> RendererSession {
        syncLocked(lock) {
            _connectCalls += 1
            let s = RecordingSession(client: binder)
            _lastSession = s
            return s
        }
    }
}

final class RecordingSession: RendererSession, @unchecked Sendable {
    let client: any PDFRendererBinder
    private let lock = NSLock()
    private var _closed = false

    init(client: any PDFRendererBinder) {
        self.client = client
    }

    var closed: Bool {
        syncLocked(lock) { _closed }
    }

    func close() {
        syncLocked(lock) { _closed = true }
    }
}

struct StaticBinder: PDFRendererBinder {
    var probeResult: ProbeResult = .rejected(kind: .rendererFailed)
    var renderResult: RenderResult = .rejected(kind: .rendererFailed)

    func probe(pdf: Data) async -> ProbeResult { probeResult }

    func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult {
        renderResult
    }
}

/// Records the `sourceRect` argument the importer passes to render so tests
/// can pin defaults / wire-shape parity.
final class RecordingBinder: PDFRendererBinder, @unchecked Sendable {
    let probeResult: ProbeResult
    let renderResult: RenderResult
    private let lock = NSLock()
    private var _lastSourceRect: RenderSourceRect?

    init(probeResult: ProbeResult, renderResult: RenderResult) {
        self.probeResult = probeResult
        self.renderResult = renderResult
    }

    var lastSourceRect: RenderSourceRect? {
        syncLocked(lock) { _lastSourceRect }
    }

    func probe(pdf: Data) async -> ProbeResult { probeResult }

    func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult {
        syncLocked(lock) { _lastSourceRect = sourceRect }
        return renderResult
    }
}

struct StubThumbnailEncoder: ThumbnailEncoder {
    var bytes: Data = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic

    func encode(render: RenderResult) throws -> Data { bytes }
}

struct ThrowingThumbnailEncoder: ThumbnailEncoder {
    func encode(render: RenderResult) throws -> Data {
        throw NSError(domain: "test", code: -1)
    }
}

struct CancellingThumbnailEncoder: ThumbnailEncoder {
    func encode(render: RenderResult) throws -> Data {
        throw CancellationError()
    }
}

final class RecordingTelemetry: DocumentTelemetryGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        syncLocked(lock) { _events }
    }

    func onImportStarted() {
        syncLocked(lock) { _events.append("started") }
    }

    func onImportSucceeded(event: DocumentImportSucceededEvent) {
        syncLocked(lock) { _events.append("succeeded:\(event.pageCount)") }
    }

    func onImportFailed(event: DocumentImportFailedEvent) {
        syncLocked(lock) { _events.append("failed:\(event.outcome)") }
    }

    func onConsumerRenderFailed(reason: ConsumerRenderFailure) {}
}

final class RecordingProcessKiller: ProcessKiller, @unchecked Sendable {
    private let lock = NSLock()
    private var _killCount = 0

    var killCount: Int {
        syncLocked(lock) { _killCount }
    }

    func killSelf() {
        syncLocked(lock) { _killCount += 1 }
    }
}

// MARK: - Importer helper

func makeTestImporter(
    config: PDFImportConfig = PDFImportConfig(),
    sessionFactory: any RendererSessionFactory = RecordingSessionFactory(),
    thumbnailEncoder: any ThumbnailEncoder = StubThumbnailEncoder(),
    idGenerator: @escaping @Sendable () -> String = { "test-id" },
    now: @escaping @Sendable () -> Int64 = { 0 },
    clockEpochMs: @escaping @Sendable () -> Int64 = { 0 }
) -> DefaultPDFImporter {
    DefaultPDFImporter(
        config: config,
        deps: DefaultPDFImporter.Deps(
            sessionFactory: sessionFactory,
            thumbnailEncoder: thumbnailEncoder,
            now: now,
            idGenerator: idGenerator,
            clockEpochMs: clockEpochMs
        )
    )
}
