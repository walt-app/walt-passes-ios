import Foundation

/// The provenance of a successfully-parsed pass. Per decision-wlt-0tn-q1, the parser accepts
/// unsigned and self-signed archives by default and surfaces their status here so the UI can
/// communicate trust to the user. Cryptographic *failures* are not reported here: they
/// produce a `ParseResult.tampered` outcome instead.
///
/// Distinguishing `unsigned` from `selfSigned` from `appleVerified` is the point of this
/// type; collapsing them in UI defeats the purpose of the lenient policy.
public enum SignatureStatus: Sendable, Equatable {
    /// No `signature` file present in the archive. The archive is just a zipped manifest.
    case unsigned

    /// The signature validates against its certificate, but the certificate chain does not
    /// terminate at an Apple-issued root.
    case selfSigned

    /// The signature validates and the certificate chain terminates at the Apple WWDR root
    /// trusted by Apple Wallet. This is the strongest provenance pkpass offers.
    case appleVerified

    /// The signature validates against the leaf certificate present in the archive, but
    /// intermediate certificates required to reach a known root were absent and the parser
    /// did not perform external fetches.
    case certChainIncomplete
}

// `toKind()` flattening to `SignatureStatusKind` is deferred: `SignatureStatusKind` lives in
// `TelemetryGuard.kt` on the Android side and is not part of this port.
