import Foundation
import PassesCore

/// The result type for every `PassRepository` call. Mirrors the `Result<T>` over
/// exceptions convention and gives the consumer a typed partition of the failure space:
/// key custody failures must be distinguishable from concurrent-open failures from
/// transient-DB failures, because the appropriate UI response differs.
///
/// On Android this is `sealed interface StorageResult<out T>`. On Swift it is an
/// `enum` with associated values; pattern matching uses exhaustive `switch`.
public enum StorageResult<T: Sendable>: Sendable {
    case success(value: T)
    case failure(error: StorageError)
}

extension StorageResult: Equatable where T: Equatable {}

/// Storage failure modes. The arms are deliberately coarse: the consumer needs enough
/// resolution to render the right user-facing message, not enough to second-guess the
/// library's internal handling.
public enum StorageError: Sendable, Equatable {
    /// The Keystore master alias has been removed (factory reset partial, app-data clear,
    /// Android upgrade dropped the entry, lock-screen credential deleted on a setup that
    /// required user-authentication-bound keys). The wrapped DB key cannot be unwrapped;
    /// the existing database is unrecoverable. The UI should surface this as
    /// "secure storage was reset by the system" and offer to re-import passes.
    ///
    /// On iOS the analogous condition is a Keychain-resident master key that has been
    /// removed (passcode disabled on a key with `WhenPasscodeSet` accessibility, app
    /// data cleared, restore-from-backup that drops `ThisDeviceOnly` items).
    case keyUnavailable

    /// The master alias is present but unwrap of the wrapped DB key failed (GCM tag
    /// mismatch, IV mismatch, alias rotated). This is a security-relevant signal
    /// distinct from `keyUnavailable`; the database file may have been replaced
    /// out-of-band.
    case keyUnwrapFailed

    /// Another process holds an exclusive lock on the database file. Transient; the
    /// caller may retry.
    case databaseLocked

    /// A row failed to deserialize at load time and was dropped (e.g. schema-migration
    /// partial failure for that row). The repository continues to serve other rows. The
    /// `recordId` names which table the unknown id belongs to (passes vs documents vs
    /// scannable cards) without requiring a free-form string.
    case integrityViolation(recordId: AnyRecordId)

    /// A document insert was rejected by the storage-side defense-in-depth check
    /// (ADR 0005 D7). Carries the same `DocumentStorageRejectedKind` as the matching
    /// `onDocumentRejected` telemetry event so callers can distinguish a defensive
    /// rejection from a transient infra failure without listening to telemetry. The row
    /// never reaches disk.
    case documentRejected(kind: DocumentStorageRejectedKind)

    /// A scannable-card insert was rejected by the kernel validator. Carries the typed
    /// kernel rejection so the consumer's error UI can localize a specific message
    /// without re-running validation. The row never reaches disk.
    case scannableCardRejected(reason: ScannableCardRejectionReason)

    /// A pass-side update (today: `user_label`) was refused by a storage-layer bound check.
    /// Carries a typed `PassUpdateRejectedKind` so the consumer localizes without re-running
    /// the check. Takes precedence over `integrityViolation`: a too-long label on an unknown
    /// id surfaces here, because the bound is checked before the row lookup.
    case passRejected(kind: PassUpdateRejectedKind)

    /// The schema version on disk is newer than this build of `PassesStorage`
    /// understands. This happens when a user downgrades the wallet app. The DB is
    /// read-only-protected until a forward-compatible build runs again.
    case unsupported(onDiskSchemaVersion: Int)

    /// Catch-all for failures that do not warrant a typed arm. Carries a stable `kind`
    /// for the telemetry guard.
    ///
    /// On Android the arm also carries `cause: Throwable?`. Swift's `Error` is not
    /// `Equatable`-friendly and would force `@unchecked Sendable`; the cause is
    /// intentionally omitted from this port. A future iOS-specific extension can layer
    /// a `causeDescription: String?` field if call sites need it.
    case unknown(kind: UnknownStorageFailureKind)
}

/// Why a `createScannableCard` call was refused. The first two arms mirror what the
/// kernel validator produces today (structural payload and label checks). The latter
/// two cover the kernel result family's remaining arms; the validator does not produce
/// them in the current build, but typing them here keeps the defensive path loud rather
/// than collapsing them into `StorageError.unknown` on the day the kernel does start
/// surfacing one.
public enum ScannableCardRejectionReason: Sendable, Equatable {
    case invalidLabel(reason: LabelRejection)
    case invalidPayload(reason: PayloadRejection)
    case unsupportedFormat(format: ScannableFormat)
    case encoderFailure(reason: EncoderFailureReason)
}

/// Why a pass-side update (today: `updatePassUserLabel`) was refused by a storage-layer
/// bound check. Mirrors passes-android `PassUpdateRejectedKind`.
public enum PassUpdateRejectedKind: Sendable, Equatable, CaseIterable {
    case labelTooLong
}

/// Bounds for the user-supplied pass-label override. The cap lives only at this layer;
/// nothing upstream of `PassRepository.updatePassUserLabel` enforces it. Mirrors
/// passes-android `PassUserLabelBounds`.
public enum PassUserLabelBounds {
    public static let maxUserLabelChars: Int = 100
}

/// Stable telemetry-friendly enumeration of the open-ended failure space. New arms here
/// are an API addition; new strings are not. Mirrors the `passes-core` discipline of
/// routing telemetry through enums rather than free-form strings.
public enum UnknownStorageFailureKind: Sendable, CaseIterable {
    case diskFull
    case permissionDenied
    case databaseCorrupt
    case serializationFailure
    case other
}
