import Foundation
import Testing

@testable import PassesStorage

/// Locks the `BackupRulesContract` surface. The Android equivalent
/// (`BackupRulesAssertionTest`) drives a Robolectric runtime to validate against a
/// merged AndroidManifest XML; that integration test is deferred until an iOS-side
/// assertion lands (it will check `URLResourceKey.isExcludedFromBackupKey` on the
/// SQLCipher file and its sidecars). These tests cover the platform-neutral contract.
@Suite("BackupRulesContract")
struct BackupRulesContractTests {

    @Test func sectionXmlElementsMatchAndroidVocabulary() {
        #expect(BackupRulesContract.Section.fullBackupContent.xmlElement == "full-backup-content")
        #expect(BackupRulesContract.Section.cloudBackup.xmlElement == "cloud-backup")
        #expect(BackupRulesContract.Section.deviceTransfer.xmlElement == "device-transfer")
    }

    @Test func requiredExcludesCoverDbAndKeyEnvelopeFiles() {
        let entries = BackupRulesContract.requiredExcludes
        let paths = entries.map(\.path)
        #expect(paths.contains("walt_passes.db"))
        #expect(paths.contains("walt_passes.db-journal"))
        #expect(paths.contains("walt_passes.db-wal"))
        #expect(paths.contains("walt_passes.db-shm"))
        #expect(paths.contains("is.walt.passes.storage.key_envelope.xml"))
    }

    @Test func requiredExcludesAreFiveEntries() {
        #expect(BackupRulesContract.requiredExcludes.count == 5)
    }

    @Test func sectionAllCasesIsTheDocumentedThree() {
        #expect(BackupRulesContract.Section.allCases == [
            .fullBackupContent,
            .cloudBackup,
            .deviceTransfer,
        ])
    }
}
