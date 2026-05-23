import Foundation

/// Telemetry-safe flattening of `SignatureStatus`. Mirrors the sealed-interface arms but
/// lives as an enum (no associated values) so it can travel through metric backends that
/// prefer dimension strings.
///
/// Android co-locates this enum in `TelemetryGuard.kt`; in iOS it gets its own file because
/// `TelemetryGuard` itself ports separately and we want the kind enum available now for the
/// `SignatureStatus.toKind()` drift detector.
public enum SignatureStatusKind: Sendable, CaseIterable {
    case unsigned
    case selfSigned
    case appleVerified
    case certChainIncomplete
}

extension SignatureStatus {
    /// Telemetry-safe flattening. The exhaustive `switch` here is the load-bearing drift
    /// detector: adding a `SignatureStatus` arm without extending `SignatureStatusKind` is a
    /// compile error, not a silent observability gap.
    public func toKind() -> SignatureStatusKind {
        switch self {
        case .unsigned: return .unsigned
        case .selfSigned: return .selfSigned
        case .appleVerified: return .appleVerified
        case .certChainIncomplete: return .certChainIncomplete
        }
    }
}
