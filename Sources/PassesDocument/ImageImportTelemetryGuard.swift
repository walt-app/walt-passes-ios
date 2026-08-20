import Foundation

/// Hook for emitting image-import observability events (mirror of Android
/// `ImageImportTelemetryGuard`). The event SHAPES are the load-bearing security
/// control: every parameter is an enum, a count, or a duration — no `String`
/// carrying a filename, no `Data` carrying file contents, no free-form map.
/// A composite import emits the SAME success event as a plain image (byte count,
/// container, dimensions, duration) — never the decoded payload. Reviewers must
/// treat any future `String` / `Data` / dictionary parameter here as a
/// security-policy change requiring re-review; `PassesDocumentGuardTests` locks
/// the shape structurally.
public protocol ImageImportTelemetryGuard: Sendable {
    func onImportStarted()
    func onImportSucceeded(event: ImageImportSucceededEvent)
    func onImportFailed(event: ImageImportFailedEvent)
}

public enum ImageImportTelemetryGuardNoOp {
    public static let shared: any ImageImportTelemetryGuard = NoOpGuard()
}

private struct NoOpGuard: ImageImportTelemetryGuard {
    func onImportStarted() {}
    func onImportSucceeded(event: ImageImportSucceededEvent) {}
    func onImportFailed(event: ImageImportFailedEvent) {}
}

public struct ImageImportSucceededEvent: Sendable, Equatable {
    public let byteCount: Int64
    public let format: ImageFormat
    public let widthPx: Int
    public let heightPx: Int
    public let durationMillis: Int64

    public init(
        byteCount: Int64, format: ImageFormat, widthPx: Int, heightPx: Int, durationMillis: Int64
    ) {
        self.byteCount = byteCount
        self.format = format
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.durationMillis = durationMillis
    }
}

public struct ImageImportFailedEvent: Sendable, Equatable {
    public let outcome: ImageImportFailureKind
    public let durationMillis: Int64

    public init(outcome: ImageImportFailureKind, durationMillis: Int64) {
        self.outcome = outcome
        self.durationMillis = durationMillis
    }
}

/// Coarse failure buckets only — the precise rejection kind rides the RESULT,
/// never telemetry, so a decoder error can never leak here.
public enum ImageImportFailureKind: Sendable, Equatable {
    case decode
    case storageHandoff
}
