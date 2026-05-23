import Foundation

/// Trust-claim surface: every byte that enters the passes pipeline arrives
/// through ``PassParser/parse(data:)``. The protocol exists so the Walt host
/// app can program against an interface; the production parser is built in
/// the Passes feature epic (ios-382.11).
///
/// Implementations MUST:
/// - Treat input as fully untrusted (no MIME or extension branching).
/// - Bound work (memory, CPU, time) — see PDF_THREAT_MODEL.md.
/// - Never log pass content; emit enum-only telemetry.
public protocol PassParser: Sendable {
    func parse(data: Data) async throws -> Pass
}

/// Errors a parser may surface. Specific reasons stay opaque to callers so
/// log lines cannot leak pass content via the error string.
public enum PassParseError: Error, Equatable, Sendable {
    case unsupportedFormat
    case malformed
    case tooLarge
    case extractionTimedOut
}
