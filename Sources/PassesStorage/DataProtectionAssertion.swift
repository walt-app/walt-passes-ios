import Foundation

/// Audit-facing verifier for the at-rest trust claim on iOS. The iOS analogue of Android's
/// `BackupRulesAssertion`: where Android validates `<exclude>` entries against the merged
/// manifest XML, this checks the live filesystem state of the database file and its sidecars.
///
/// `BackupRulesContract` (in this module) is the platform-neutral statement of WHAT must be
/// excluded; this type is the iOS check of WHETHER it is. A security reviewer can call
/// `assert(databaseURL:)` to confirm, at runtime, that the database the app actually opened
/// is excluded from cloud backup and (on a device) protected at rest.
///
/// **Key-contract note.** Under the ios-b1f Data Protection decision there is no app-managed
/// database key — encryption-at-rest is the OS class key (`FileProtectionType.complete`),
/// bound to the device passcode and Secure Enclave. The kernel's SQLCipher-shaped
/// `PassKeyProvider` / `DatabaseKey` / `PRAGMA key` contract therefore has no iOS
/// counterpart and is deliberately unused; the verifiable claim it would have backed
/// ("the data is encrypted at rest and cannot be read off-device") is instead the file
/// protection + backup-exclusion this assertion checks.
public enum DataProtectionAssertion {
    /// A single file's protection state, for the report.
    public struct FileState: Sendable, Equatable {
        public let fileName: String
        public let exists: Bool
        public let excludedFromBackup: Bool
        /// `true` if the file is marked `FileProtectionType.complete`. Always `nil` off-iOS,
        /// where file protection is not a filesystem concept.
        public let completeProtection: Bool?
    }

    /// The outcome of asserting the at-rest claim over a database URL.
    public struct Report: Sendable, Equatable {
        public let states: [FileState]

        /// Every file that exists is excluded from backup. (Absent sidecars are vacuously
        /// fine — SQLite may not have created a WAL/SHM yet.)
        public var allExistingExcludedFromBackup: Bool {
            states.filter(\.exists).allSatisfy(\.excludedFromBackup)
        }

        /// On iOS, every file that exists is `FileProtectionType.complete`. Off-iOS this is
        /// vacuously `true` (file protection does not apply to the macOS test host).
        public var allExistingCompleteProtected: Bool {
            states.filter(\.exists).allSatisfy { $0.completeProtection ?? true }
        }

        /// The trust claim holds: existing files are both backup-excluded and (on iOS)
        /// complete-protected.
        public var holds: Bool { allExistingExcludedFromBackup && allExistingCompleteProtected }
    }

    /// Inspects the database file + sidecars at `databaseURL` and reports their protection
    /// state. Pure read; never mutates the files.
    public static func assert(databaseURL: URL) -> Report {
        let states = GrdbDatabaseFactory.protectedFileURLs(for: databaseURL).map { url in
            inspect(url)
        }
        return Report(states: states)
    }

    private static func inspect(_ url: URL) -> FileState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return FileState(
                fileName: url.lastPathComponent,
                exists: false,
                excludedFromBackup: false,
                completeProtection: nil
            )
        }
        let excluded =
            (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup ?? false

        var complete: Bool?
        #if os(iOS)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let protection = attributes?[.protectionKey] as? FileProtectionType
        complete = protection == .complete
        #else
        complete = nil
        #endif

        return FileState(
            fileName: url.lastPathComponent,
            exists: true,
            excludedFromBackup: excluded,
            completeProtection: complete
        )
    }
}
