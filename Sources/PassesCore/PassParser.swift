import Foundation

/// The single entrypoint into PassesCore. Implementations must be safe to call concurrently
/// across threads (each call holds only stack-local state plus the immutable `ParserConfig`),
/// and must never throw out of `parse`: every error path is encoded as a `ParseResult` arm.
///
/// Returning a sealed result instead of `Result<Pass, Error>` is deliberate here: the failure
/// space is rich enough that a generic `Error` would lose the partition between
/// tampered / malformed / unsupported that the UI must distinguish.
///
/// The production implementation (`DefaultPassParser` on Android) pulls a JSON tokenizer
/// and PKCS#7 verifier with no clean Swift mapping; landing on iOS is deferred to a
/// follow-up bead. This file ports the public surface only.
public protocol PassParser: Sendable {
    /// Parse `source` into a `ParseResult`. Synchronous and CPU-bound: signature verification,
    /// JSON tokenization, and zip extraction all run on the calling thread. Wrap calls in
    /// `Task.detached` (or another off-main isolation) when invoking from a UI context.
    ///
    /// Never throws: every failure mode is encoded as a `ParseResult` arm.
    func parse(source: PassSource) -> ParseResult
}

/// Factory namespace for the production parser. The concrete pipeline (`DefaultPassParser`) is
/// internal; `PassParserFactory.create` is the only public way to obtain one, keeping the
/// implementation a private detail. (A `static` on `PassParser` itself cannot be called on the
/// existential metatype, so the factory lives on its own type.)
public enum PassParserFactory {
    public static func create(config: ParserConfig = ParserConfig()) -> any PassParser {
        DefaultPassParser(config: config)
    }
}

/// A PKPASS archive in a form the parser can stream. The parser materializes the input into
/// memory only as needed, applying `ParserConfig.maxArchiveBytes` and friends along the way.
///
/// `@unchecked Sendable` because the `stream` arm wraps `InputStream` (Foundation type that
/// is not formally Sendable). The contract documented on `stream` shifts ownership to the
/// caller: they must not mutate the stream concurrently with `parse`, so the value is safe
/// to hand to a parser running on a background queue.
public enum PassSource: @unchecked Sendable {
    /// Whole archive already resident in memory.
    case bytes(Data)

    /// Streaming source. `sizeHintBytes`, when known, is checked against
    /// `ParserConfig.maxArchiveBytes` up front to fail fast on oversized payloads. The
    /// parser does not close the underlying stream; the caller owns its lifecycle.
    case stream(InputStream, sizeHintBytes: Int64?)
}
