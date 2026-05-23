import Foundation

/// Backup-rules trust contract for `PassesStorage`. Encodes what the trust claim
/// "pass data is excluded from cloud backup" means as data the assertion can verify.
///
/// On Android the assertion validates against the consumer's merged manifest XML. On
/// iOS the analogous control is `URLResourceKey.isExcludedFromBackupKey` set on the
/// database file (and its WAL / journal / shm sidecars) plus the wrapped-key Keychain
/// item's `kSecAttrSynchronizable = false`. The iOS-side assertion is owned by a
/// separate bead; this contract is the platform-neutral statement of what must be
/// excluded.
///
/// This object is the audit-facing entry point. A security researcher reading the
/// trust claim should land on `requiredExcludes` to see exactly which files the
/// library insists are excluded from cloud backup and device-to-device transfer.
public enum BackupRulesContract {

    /// Backup rule sections the assertion validates. The `xmlElement` strings mirror
    /// Android's backup-rules XML vocabulary verbatim so the contract is portable
    /// between platforms — an iOS-side assertion that walks plist or `URLResourceKey`
    /// state still expresses its findings in the same `Section` vocabulary.
    public enum Section: Sendable, CaseIterable, Equatable {
        case fullBackupContent
        case cloudBackup
        case deviceTransfer

        public var xmlElement: String {
            switch self {
            case .fullBackupContent: return "full-backup-content"
            case .cloudBackup: return "cloud-backup"
            case .deviceTransfer: return "device-transfer"
            }
        }
    }

    /// A single `<exclude domain="..." path="..."/>` entry. On iOS the `domain` and
    /// `path` fields are not directly meaningful (iOS apps live in their sandbox), but
    /// the values are preserved verbatim so the contract round-trips between
    /// platforms.
    public struct RequiredExclude: Sendable, Equatable, Hashable {
        public let domain: String
        public let path: String

        public init(domain: String, path: String) {
            self.domain = domain
            self.path = path
        }
    }

    /// Entries the library requires every consumer rules resource to carry.
    public static let requiredExcludes: [RequiredExclude] = [
        RequiredExclude(domain: "database", path: "walt_passes.db"),
        RequiredExclude(domain: "database", path: "walt_passes.db-journal"),
        RequiredExclude(domain: "database", path: "walt_passes.db-wal"),
        RequiredExclude(domain: "database", path: "walt_passes.db-shm"),
        RequiredExclude(domain: "sharedpref", path: "is.walt.passes.storage.key_envelope.xml"),
    ]
}
