import Foundation

/// Common surrogate-key surface shared by `PassRecordId`, `DocumentRecordId`, and
/// `ScannableCardRecordId`. Carrying a typed wrapper rather than a raw `Int64` keeps
/// `StorageError.integrityViolation` honest: the arm names which table the unknown id
/// belongs to, so a future telemetry consumer or unit test cannot misread a document id
/// as a pass id.
///
/// On Android this is a `sealed interface RecordId { val value: Long }`. On Swift it is
/// modeled as a protocol with concrete `struct` arms; pattern matching is via `switch`
/// over a discriminator (`as?` casts) the same way exhaustive `when` works in Kotlin.
public protocol RecordId: Sendable, Hashable {
    var value: Int64 { get }
}

/// Auto-incremented primary-key surrogate for a row in the `passes` table. Distinct from
/// the PKPASS identity tuple (`type`, `serialNumber`, `organizationName`) because the same
/// identity may legitimately be re-imported across the same `id` over time.
public struct PassRecordId: RecordId, Equatable {
    public let value: Int64

    public init(_ value: Int64) {
        self.value = value
    }
}

/// Auto-incremented primary-key surrogate for a row in the `documents` table. Mirrors
/// `PassRecordId`'s role for the pass side. Wrapping the id in a typed struct prevents an
/// accidental cross-domain substitution (e.g., passing a `PassRecordId` to
/// `loadDocumentBytes`) at compile time rather than runtime.
public struct DocumentRecordId: RecordId, Equatable {
    public let value: Int64

    public init(_ value: Int64) {
        self.value = value
    }
}

/// Auto-incremented primary-key surrogate for a row in the `scannable_cards` table.
/// Distinct from `ScannableCardId` (which is the kernel's opaque string identifier
/// exposed on `ScannableCard`) so that a row id cannot be silently substituted for any
/// other `RecordId` arm at compile time.
public struct ScannableCardRecordId: RecordId, Equatable {
    public let value: Int64

    public init(_ value: Int64) {
        self.value = value
    }
}

/// Type-erased wrapper for any `RecordId` arm. Used by `StorageError.integrityViolation`
/// so the arm can carry whichever record-id type the missing row belongs to without
/// erasing the discriminator at the use site.
public enum AnyRecordId: Sendable, Hashable {
    case pass(PassRecordId)
    case document(DocumentRecordId)
    case scannableCard(ScannableCardRecordId)

    public var value: Int64 {
        switch self {
        case .pass(let id): return id.value
        case .document(let id): return id.value
        case .scannableCard(let id): return id.value
        }
    }
}
