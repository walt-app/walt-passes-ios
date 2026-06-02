import Foundation
import GRDB

/// Maps a thrown error from the GRDB write/read path onto a typed `StorageError`. Mirrors
/// the coarse partition Android's repository applies in its `runIo` wrapper: a downgrade is
/// `.unsupported`, a SQLite busy/locked code is `.databaseLocked`, a corruption/full-disk
/// code routes to the matching `UnknownStorageFailureKind`, and everything else collapses to
/// `.unknown(.other)`. The consumer only needs enough resolution to pick the right user
/// message, not the underlying exception.
///
/// `DocumentRejected` / `ScannableCardRejected` / `IntegrityViolation` are NOT produced here:
/// those are deliberate, in-band results the stores return before any throw, so they reach
/// the caller without passing through this mapper.
enum StorageErrorMapper {
    static func map(_ error: any Error) -> StorageError {
        if let open = error as? DatabaseOpenError {
            switch open {
            case .unsupported(let version): return .unsupported(onDiskSchemaVersion: version)
            case .missingMigration: return .unknown(kind: .databaseCorrupt)
            }
        }
        if let dbError = error as? DatabaseError {
            return map(dbError)
        }
        return .unknown(kind: .other)
    }

    private static func map(_ error: DatabaseError) -> StorageError {
        switch error.resultCode.primaryResultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            return .databaseLocked
        case .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return .unknown(kind: .databaseCorrupt)
        case .SQLITE_FULL:
            return .unknown(kind: .diskFull)
        case .SQLITE_PERM, .SQLITE_AUTH, .SQLITE_READONLY, .SQLITE_CANTOPEN:
            return .unknown(kind: .permissionDenied)
        default:
            return .unknown(kind: .other)
        }
    }
}
