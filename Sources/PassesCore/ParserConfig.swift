import Foundation

/// Defensive limits and trust toggles applied during parsing. Defaults are tuned for the v1
/// consumer (Walt Android), erring on the side of generosity for legitimate passes from large
/// carriers (which can carry sizeable backgrounds and many locales) while still cutting off
/// obvious zip-bomb / JSON-bomb / decompression-bomb shapes far below process-OOM territory.
///
/// Limits are enforced *before* full materialization, e.g. `maxArchiveBytes` is checked
/// against the input stream length before unzipping; `maxEntries` is checked while iterating
/// the central directory; `maxJsonDepth` is enforced inside the JSON reader.
///
/// `maxJsonStringBytes` is intentionally cross-format: it bounds individual string
/// values in `pass.json` *and* individual values in `<locale>.lproj/pass.strings`. The
/// two formats share an attack surface (a single oversized string deferring allocation
/// to a downstream consumer), so a single ceiling is the right knob; introducing a
/// separate `maxStringsValueBytes` would be a knob without a turner. Tighten this value
/// and both parsers tighten with it.
///
/// Use `strict` for tests and audit tooling that should reject anything not Apple-signed.
public struct ParserConfig: Sendable, Equatable {
    public let maxArchiveBytes: Int64
    public let maxEntries: Int
    public let maxEntryBytes: Int64
    public let maxJsonDepth: Int
    public let maxJsonStringBytes: Int
    public let maxImagePixelCount: Int
    public let maxLocaleCount: Int
    public let acceptUnsignedArchives: Bool
    public let acceptSelfSignedCertificates: Bool

    public init(
        maxArchiveBytes: Int64 = Self.defaultMaxArchiveBytes,
        maxEntries: Int = Self.defaultMaxEntries,
        maxEntryBytes: Int64 = Self.defaultMaxEntryBytes,
        maxJsonDepth: Int = Self.defaultMaxJsonDepth,
        maxJsonStringBytes: Int = Self.defaultMaxJsonStringBytes,
        maxImagePixelCount: Int = Self.defaultMaxImagePixelCount,
        maxLocaleCount: Int = Self.defaultMaxLocaleCount,
        acceptUnsignedArchives: Bool = true,
        acceptSelfSignedCertificates: Bool = true
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxJsonDepth = maxJsonDepth
        self.maxJsonStringBytes = maxJsonStringBytes
        self.maxImagePixelCount = maxImagePixelCount
        self.maxLocaleCount = maxLocaleCount
        self.acceptUnsignedArchives = acceptUnsignedArchives
        self.acceptSelfSignedCertificates = acceptSelfSignedCertificates
    }

    public static let defaultMaxArchiveBytes: Int64 = 10 * 1024 * 1024
    public static let defaultMaxEntries: Int = 256
    public static let defaultMaxEntryBytes: Int64 = 4 * 1024 * 1024
    public static let defaultMaxJsonDepth: Int = 16
    public static let defaultMaxJsonStringBytes: Int = 1 * 1024 * 1024
    public static let defaultMaxImagePixelCount: Int = 4096 * 4096
    public static let defaultMaxLocaleCount: Int = 64

    /// A configuration that rejects unsigned and self-signed archives. Provided for tests
    /// and for an opt-in stricter ingestion mode; not the default per
    /// decision-wlt-0tn-q1.
    public static let strict: ParserConfig = ParserConfig(
        acceptUnsignedArchives: false,
        acceptSelfSignedCertificates: false
    )
}

// `telemetryGuard` field is deferred: `TelemetryGuard` is not part of this port.

public extension ResourceLimit {
    /// The configured ceiling for this resource limit, expressed in the unit the parser
    /// actually compares against (bytes for size limits, count for everything else). Returned
    /// as `Int64` so the caller can compare without overflow concerns on archive sizes.
    ///
    /// The exhaustive `switch` is the drift detector: adding a `ResourceLimit` arm without
    /// giving it a `ParserConfig` field is a compile error here, so an enum value can never
    /// silently lack a backing limit.
    func limitFrom(_ config: ParserConfig) -> Int64 {
        switch self {
        case .archiveSize: return config.maxArchiveBytes
        case .entryCount: return Int64(config.maxEntries)
        case .entrySize: return config.maxEntryBytes
        case .jsonDepth: return Int64(config.maxJsonDepth)
        case .jsonStringSize: return Int64(config.maxJsonStringBytes)
        case .imagePixelCount: return Int64(config.maxImagePixelCount)
        case .localeCount: return Int64(config.maxLocaleCount)
        }
    }
}
