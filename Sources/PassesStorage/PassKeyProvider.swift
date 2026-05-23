import Foundation

/// Source of the 32-byte raw key handed to SQLCipher's `PRAGMA key`. The production
/// iOS implementation will wrap a randomly generated key with a Keychain / Secure
/// Enclave-resident master (see ADR 0002 D2 for the Android-side rationale; the iOS
/// equivalent is a separate bead); a test implementation supplies a fixed key for
/// round-trip tests of the schema.
///
/// The production implementation is platform-specific and is intentionally NOT in
/// scope for this port. Keeping `PassKeyProvider` as a protocol lets the contract be
/// exercised without depending on Keychain / Secure Enclave APIs.
public protocol PassKeyProvider: Sendable {
    /// Returns the 32-byte raw database key. Implementations MUST zero out any local
    /// buffers holding the key bytes after returning; SQLCipher takes ownership of the
    /// returned bytes internally.
    ///
    /// Returns `StorageError.keyUnavailable` if the master alias is gone; returns
    /// `StorageError.keyUnwrapFailed` if the wrapped blob exists but cannot be
    /// unwrapped.
    func provideDatabaseKey() -> StorageResult<DatabaseKey>

    /// Reports which key backing was actually selected for the master key. Surfaced
    /// via `StorageTelemetryGuard.onKeyProviderInitialized`; useful in the wallet UI
    /// when the user wants to verify hardware-backing on their device.
    var keyBacking: KeyBacking { get }
}

/// Wrapper around the raw 32-byte database key. Exists to make accidental logging
/// discouragingly verbose: the type deliberately overrides its description to a
/// redacted form, and exposes byte access only via `withBytes` (synchronous borrow) or
/// `copyForRetainedConsumer` (lifetime-tied handoff).
///
/// Each `DatabaseKey` is single-use: the first call to either access method consumes
/// it, and any subsequent call traps via `preconditionFailure`. Silently re-handing an
/// already-zeroed master to SQLCipher is the wpass-aio symptom class (page-1 decrypt
/// with all-zero key surfaces as `SQLiteOutOfMemoryException`), so the second hand-off
/// must surface loudly at the call site, not as opaque corruption. Single-threaded by
/// construction; callers must not consume from multiple threads.
///
/// On Android this is a class with mutable state. On Swift it is a `final class` so
/// the consume-once flag is by-reference; using a `struct` would copy the flag on
/// every call and break single-use semantics.
public final class DatabaseKey: CustomStringConvertible, @unchecked Sendable {
    private var bytes: [UInt8]
    private var consumed: Bool = false

    public init(_ bytes: Data) {
        precondition(bytes.count == 32, "DatabaseKey must be exactly 32 bytes")
        self.bytes = Array(bytes)
    }

    public convenience init(_ bytes: [UInt8]) {
        self.init(Data(bytes))
    }

    /// Hands the raw key bytes to `block` and zeros the internal buffer when `block`
    /// returns. Callers MUST NOT retain the byte buffer beyond the block. Traps if
    /// this `DatabaseKey` has already been consumed.
    @discardableResult
    public func withBytes<R>(_ block: (inout [UInt8]) throws -> R) rethrows -> R {
        precondition(!consumed, "DatabaseKey already consumed")
        consumed = true
        defer { zeroInternal() }
        return try block(&bytes)
    }

    /// Returns a fresh `RetainedKeyBuffer` holding a private copy of the key bytes,
    /// then zeros this `DatabaseKey`'s internal buffer. Callers MUST `close()` the
    /// result once the long-lived consumer no longer needs the bytes. Traps if this
    /// `DatabaseKey` has already been consumed.
    ///
    /// Required by SQLCipher: the C-level password buffer is held by reference (no
    /// copy), and the connection pool re-reads the buffer on every pool connection it
    /// opens. Zeroing the buffer before the connection pool is done re-keys new pool
    /// connections with all zeros.
    public func copyForRetainedConsumer() -> RetainedKeyBuffer {
        precondition(!consumed, "DatabaseKey already consumed")
        consumed = true
        let copy = bytes
        zeroInternal()
        return RetainedKeyBuffer(bytes: copy)
    }

    public var description: String { "DatabaseKey(redacted)" }

    private func zeroInternal() {
        for i in 0..<bytes.count { bytes[i] = 0 }
    }
}

/// A private 32-byte buffer handed off to a long-lived native consumer (SQLCipher's
/// connection pool). The initializer is `internal` so the only construction path is
/// `DatabaseKey.copyForRetainedConsumer`; the buffer is `internal` so only same-module
/// callers (the SQLCipher binding wrapper, once added) can hand it to the native pool.
/// `close()` zeros the buffer; callers MUST close it once the consumer is done.
public final class RetainedKeyBuffer: @unchecked Sendable {
    internal private(set) var bytes: [UInt8]
    private var closed: Bool = false

    internal init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for i in 0..<bytes.count { bytes[i] = 0 }
    }

    deinit { close() }
}

/// Reports which Keystore / Secure Enclave backing was used for the master key that
/// wraps the DB key. The wallet UI surfaces this so users can verify hardware-backing
/// on their device.
///
/// `software` is reachable on simulators and on devices whose secure-element
/// implementation declined to provide a hardware-backed key; the library does NOT
/// refuse to operate in this case, because doing so would brick the wallet on
/// simulator-based development.
///
/// Arm names mirror Android verbatim. The iOS-side production provider will map
/// Secure Enclave -> `.strongBox` (closest analogue: hardware-isolated secure
/// element) when this port lands an iOS-specific implementation. The mapping decision
/// is owned by the implementation bead, not this contract.
public enum KeyBacking: Sendable, CaseIterable {
    case strongBox
    case tee
    case software
}
