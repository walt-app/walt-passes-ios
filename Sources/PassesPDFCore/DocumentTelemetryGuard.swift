import Foundation

/// Hook for emitting PDF-import observability events to a host telemetry pipeline. The
/// shape of the event types is the load-bearing security control here: every parameter is
/// either an enum, a count, or a duration. There is no `String` carrying filename, no
/// `Data` carrying file contents, no map of free-form attributes.
///
/// That structural restriction is the trust claim mirroring `PassesCore`'s
/// `TelemetryGuard`: PDF content and identifying metadata never appear in logs or
/// telemetry, by interface construction. A consumer cannot accidentally log a filename
/// through this interface because the interface refuses to accept one. Reviewers should
/// treat any future addition of a `String` / `Data` / dictionary parameter to these events
/// as a security-policy change requiring re-review.
///
/// The events are also intentionally narrower than the parser equivalents: there is no
/// "page-by-page render started" event, because per-page render timing leaks structural
/// information about a document the consumer would be tempted to act on.
public protocol DocumentTelemetryGuard: Sendable {
    func onImportStarted()
    func onImportSucceeded(event: DocumentImportSucceededEvent)
    func onImportFailed(event: DocumentImportFailedEvent)

    /// A consumer-side render attempt produced no bitmap. Distinct from the renderer
    /// service's own failure path: this fires inside the hosting UI module after a
    /// successful render result has been received, when reconstructing the bitmap
    /// throws - out of memory, dimension mismatch, or a handle already closed by a
    /// parallel render. The visible outcome is a blank page that the next swipe
    /// re-attempts; without this hook the path is silent.
    ///
    /// The PII discipline is upheld by parameter shape: only the enum `reason` is
    /// accepted. No error type, no message, no dimensions.
    func onConsumerRenderFailed(reason: ConsumerRenderFailure)
}

/// Singleton no-op guard. Default `telemetryGuard` in `PDFImportConfig`.
public enum DocumentTelemetryGuardNoOp {
    public static let shared: DocumentTelemetryGuard = NoOpGuard()
}

private struct NoOpGuard: DocumentTelemetryGuard {
    func onImportStarted() {}
    func onImportSucceeded(event: DocumentImportSucceededEvent) {}
    func onImportFailed(event: DocumentImportFailedEvent) {}
    func onConsumerRenderFailed(reason: ConsumerRenderFailure) {}
}

public struct DocumentImportSucceededEvent: Sendable, Equatable {
    public let byteCount: Int64
    public let pageCount: Int
    public let durationMillis: Int64

    public init(byteCount: Int64, pageCount: Int, durationMillis: Int64) {
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.durationMillis = durationMillis
    }
}

public struct DocumentImportFailedEvent: Sendable, Equatable {
    public let outcome: DocumentRejectedKind
    public let durationMillis: Int64

    public init(outcome: DocumentRejectedKind, durationMillis: Int64) {
        self.outcome = outcome
        self.durationMillis = durationMillis
    }
}

/// Why a consumer-side bitmap reconstruction failed. Mirrors the three deterministic
/// Android-side failure shapes plus a defensive `other` catch-all:
///
///  - `outOfMemory` - bitmap allocation threw an out-of-memory error.
///  - `sharedMemoryUnavailable` - the shared-memory handle was already closed, typically
///    by a parallel render task that cancelled and ran the cleanup branch.
///  - `dimensionMismatch` - the renderer-reported `widthPx * heightPx * 4` bytes did not
///    match the mapped buffer.
///  - `other` - any other error. Preserved to keep the outer catch surface safe against
///    future platform changes; spike here means a new failure class to triage.
public enum ConsumerRenderFailure: Sendable, CaseIterable {
    case outOfMemory
    case sharedMemoryUnavailable
    case dimensionMismatch
    case other
}
