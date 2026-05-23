import Foundation

/// Defensive limits and the telemetry hook applied during PDF import. Defaults pin the
/// hard caps from ADR 0005 D7: 25 MB total, 10 pages, 5 s render timeout. They are
/// exposed as constants so consumers and tests refer to the same numbers, and so
/// changing a default is a deliberate, test-breaking edit (see `PublicApiSurfaceTests`).
///
/// The limits are enforced before full materialization: `maxBytes` is checked against
/// the input source length before the renderer service even sees the bytes; `maxPages`
/// is checked after the page-count probe but before any rendering work; `renderTimeoutMs`
/// bounds each render call independently and is the watchdog the renderer uses before
/// terminating itself (D7 timeout-then-kill behaviour).
///
/// `telemetryGuard` follows the same load-bearing-by-shape contract as `PassesCore`:
/// the events accept enums, counts, and durations only.
public struct PDFImportConfig: Sendable {
    public static let defaultMaxBytes: Int64 = 25 * 1024 * 1024
    public static let defaultMaxPages: Int = 10
    public static let defaultRenderTimeoutMs: Int64 = 5_000

    public let maxBytes: Int64
    public let maxPages: Int
    public let renderTimeoutMs: Int64
    public let telemetryGuard: DocumentTelemetryGuard

    public init(
        maxBytes: Int64 = PDFImportConfig.defaultMaxBytes,
        maxPages: Int = PDFImportConfig.defaultMaxPages,
        renderTimeoutMs: Int64 = PDFImportConfig.defaultRenderTimeoutMs,
        telemetryGuard: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
    ) {
        self.maxBytes = maxBytes
        self.maxPages = maxPages
        self.renderTimeoutMs = renderTimeoutMs
        self.telemetryGuard = telemetryGuard
    }
}
