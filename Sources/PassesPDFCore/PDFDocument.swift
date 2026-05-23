import Foundation

/// Opaque identifier for a stored `PDFDocument`. Wrapped in a struct so calling code
/// cannot accidentally substitute a `String` from another domain (a pass id, a filename,
/// a user input) into APIs that expect a document id.
public struct PDFDocumentId: Sendable, Hashable, Equatable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// The pure-Swift model for a successfully-imported PDF. Mirrors the role `Pass` plays in
/// `PassesCore` for pkpass archives, but is deliberately a *sibling* concept (per ADR 0005
/// D1) - `PDFDocument` and `Pass` share no superclass. Documents are not signature-verified
/// (D5); their trust caption is sourced from `provenance`, which has a single arm by design.
///
/// The displayed `displayLabel` is supplied at import time by the consumer; the model layer
/// never derives it from PDF metadata, because metadata is part of the
/// no-extraction-from-content discipline (D4). Callers should pass a filename if they have
/// one and a date-based fallback ("PDF, added <date>") otherwise.
public struct PDFDocument: Sendable, Equatable {
    public let id: PDFDocumentId
    public let displayLabel: String
    public let byteCount: Int64
    public let pageCount: Int
    public let importedAtEpochMs: Int64
    public let provenance: Provenance

    public init(
        id: PDFDocumentId,
        displayLabel: String,
        byteCount: Int64,
        pageCount: Int,
        importedAtEpochMs: Int64,
        provenance: Provenance = .userProvided
    ) {
        self.id = id
        self.displayLabel = displayLabel
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.importedAtEpochMs = importedAtEpochMs
        self.provenance = provenance
    }
}

/// Where a `PDFDocument` came from. Single arm by design: the only legitimate source today
/// is the user importing a file from their device. The arm exists not because there are
/// alternatives but because *not having* this enum would let a future contributor add a
/// silent "downloaded by Walt" provenance without a code-review trail.
///
/// The presence of this enum also signals the policy in ADR 0005 D5: PDFs are NEVER
/// signature-verified. There is no `SignatureStatus` analogue for documents, by design.
/// Adding a second arm here is a security-policy change requiring re-review.
public enum Provenance: Sendable, CaseIterable {
    case userProvided
}

/// The reasons a PDF import can be rejected, flattened to a telemetry-safe enum (no string
/// payloads, ever - see `DocumentTelemetryGuard`). Each arm pins a specific control from
/// ADR 0005:
///
///  - `oversizedAtImport` / `tooManyPages` -> D7 hard caps.
///  - `notAPdf` -> header sniff before any decoding work; cuts off MIME-spoofing.
///  - `encrypted` -> D6 (encrypted PDFs are rejected at import).
///  - `rendererFailed` -> the isolated renderer service (D3) returned an error or timed out
///    during page-count probing; we never report the underlying decoder error string.
///  - `unsupportedAndroidVersion` -> ADR 0005 G.1 runtime gate on Android (preserved here
///    for wire-format parity with the Android downstream binder layer). On iOS this arm is
///    never produced by the importer; it exists so the rejection-kind enum stays a 1:1
///    mirror of the Android source.
///  - `encoderFailed` -> post-renderer PNG-encoding failure inside the importer. Distinct
///    from `rendererFailed` so telemetry can tell "PDF decoder choked on this file" apart
///    from "the device ran out of RAM during PNG encoding."
///  - `storageHandoffFailed` -> the consumer-supplied `persist` callback threw after a
///    successful render. Trust band is the storage layer (downstream of this module);
///    a spike here points the consumer at storage infra rather than the renderer.
///
/// Reviewers should treat any future addition of a string-bearing failure arm (e.g. an
/// "errorMessage" associated value) as a security-policy change.
public enum DocumentRejectedKind: Sendable, CaseIterable {
    case oversizedAtImport
    case notAPdf
    case encrypted
    case tooManyPages
    case rendererFailed
    case unsupportedAndroidVersion
    case encoderFailed
    case storageHandoffFailed
}
