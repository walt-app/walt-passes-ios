import Foundation

/// Outcome of attempting to parse a PKPASS archive. The four arms partition along trust /
/// recoverability lines so that the consumer UI can render distinct states without inspecting
/// exception messages:
///
/// - `success`: a usable `Pass`. Trust level is in the accompanying `SignatureStatus`.
/// - `tampered`: the archive's signature or per-file hash did not validate. Never coalesce
///   with `malformed` in UI; tampering implies a security event, malformedness does not.
/// - `malformed`: the archive structure is invalid or exceeds a configured resource limit.
/// - `unsupported`: the archive is structurally valid but uses a feature this parser does
///   not handle (e.g. an unknown formatVersion).
public enum ParseResult: Sendable, Equatable {
    case success(pass: Pass, signatureStatus: SignatureStatus)
    case tampered(reason: TamperReason)
    case malformed(reason: MalformedReason)
    case unsupported(reason: UnsupportedReason)
}

public enum TamperReason: Sendable, Equatable {
    /// The PKCS#7 detached signature failed cryptographic verification against `manifest.json`.
    case manifestSignatureMismatch
    /// A file's SHA-1 hash in `manifest.json` did not match the file's actual contents.
    case fileHashMismatch
    /// The signature blob is structurally a PKCS#7 envelope but cryptographically malformed.
    case signatureCryptoFailure
    /// The CMS / PKCS#7 envelope parsed cleanly but the verifier could not pair it
    /// with a signing certificate. Two shapes reach this arm:
    ///
    ///  1. The envelope contains zero SignerInfo entries (a structurally legal but
    ///     vacuous CMS).
    ///  2. The first SignerInfo's identifier (IssuerAndSerialNumber or
    ///     SubjectKeyIdentifier) does not match any certificate in the envelope's
    ///     certificate set.
    ///
    /// Both are folded together because the operational signal is identical: the
    /// envelope is well-formed but unsignable, which a corrupt blob is not.
    /// Distinct from `signatureCryptoFailure` (structural corruption and unexpected
    /// crypto exceptions) so telemetry can distinguish a malformed-but-parseable
    /// envelope from a genuine cryptographic miss. Surfaced as a separate arm
    /// because folding it into `signatureCryptoFailure` hid the wpass-4js
    /// regression: a misclassified signer-ID code path looked identical in logs
    /// to a corrupted blob, which bought the bug months of unflagged production
    /// exposure.
    case signerCertificateMissing
}

public enum MalformedReason: Sendable, Equatable {
    case notAZipArchive
    case missingPassJson
    case missingManifest
    case invalidPassJson
    case invalidManifest
    /// A `<locale>.lproj/pass.strings` file is structurally invalid (charset error,
    /// unterminated token, missing `=`/`;`, unrecognized escape, unpaired surrogate).
    /// Surfaced separately from `invalidPassJson` so telemetry and UI can distinguish
    /// a malformed localization payload from a malformed pass.json — the two have
    /// different operational implications (a bad .strings file degrades one locale;
    /// a bad pass.json takes the whole pass down).
    case invalidStrings
    case resourceLimitExceeded(limit: ResourceLimit)
}

/// Which guard from `ParserConfig` tripped. Surfaced separately from the structural failures
/// so monitoring (via `TelemetryGuard`) can distinguish a misconfiguration from an attack
/// payload.
public enum ResourceLimit: Sendable, CaseIterable {
    case archiveSize
    case entryCount
    case entrySize
    case jsonDepth
    case jsonStringSize
    case imagePixelCount
    case localeCount
}

public enum UnsupportedReason: Sendable, Equatable {
    case formatVersion(version: Int)
    /// The pass.json declared a top-level pass-style key this parser does not implement.
    case unknownPassStyle(raw: String)
    case encryptedArchive
}

// `toFailureKind()` / `toFailureReason()` flattenings are deferred: they target
// `ParseFailureKind` / `ParseFailureReason`, which live in `TelemetryGuard.kt` on the Android
// side and are not part of this port.
