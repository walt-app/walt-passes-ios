import Foundation

/// Telemetry-safe flattening of `ParseResult` failure arms. Resource-limit hits are surfaced
/// as their own bucket because they are the most operationally-meaningful failure for tuning
/// `ParserConfig` limits.
///
/// Android co-locates this enum in `TelemetryGuard.kt`; on iOS it gets its own file (the
/// `SignatureStatusKind` precedent) because `TelemetryGuard` itself ports separately and the
/// kind enum is needed now by `PassImportRejectionSheet`.
public enum ParseFailureKind: Sendable, CaseIterable {
    case tampered
    case malformed
    case unsupported
    case resourceLimitExceeded
}

extension ParseResult {
    /// Telemetry-safe flattening of failure outcomes. `success` returns `nil` — success is
    /// not a failure event. The exhaustive `switch` is the drift detector: adding a
    /// `ParseResult` arm without extending `ParseFailureKind` is a compile error.
    /// Resource-limit hits are pulled out of `malformed` into their own bucket because
    /// operationally they are the most useful failure to alert on (they signal a too-tight
    /// `ParserConfig`, not an attack payload). Mirror of Android's `ParseResult.toFailureKind()`.
    public func toFailureKind() -> ParseFailureKind? {
        switch self {
        case .success: return nil
        case .tampered: return .tampered
        case .malformed(let reason):
            if case .resourceLimitExceeded = reason { return .resourceLimitExceeded }
            return .malformed
        case .unsupported: return .unsupported
        }
    }
}
