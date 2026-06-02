import Foundation
import GRDB
import Testing

@testable import PassesStorage

/// Coverage for the at-rest protection applied by `GrdbDatabaseFactory` and verified by
/// `DataProtectionAssertion` (ios-b1f.5). Backup exclusion is cross-platform and asserted
/// here on the macOS test host; `FileProtectionType.complete` is iOS-only and is a documented
/// no-op off-device, so the assertion treats it as vacuously satisfied on macOS.
@Suite("DataProtection")
struct DataProtectionTests {

    private func withTempDatabase<R>(_ body: (URL) throws -> R) rethrows -> R {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_protect_\(UUID().uuidString).db")
        defer {
            for url in GrdbDatabaseFactory.protectedFileURLs(for: url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return try body(url)
    }

    @Test func openedDatabaseIsExcludedFromBackup() throws {
        try withTempDatabase { url in
            _ = try GrdbDatabaseFactory.open(at: url)
            let report = DataProtectionAssertion.assert(databaseURL: url)
            // The main DB file exists and must be backup-excluded.
            let main = report.states.first { $0.fileName == url.lastPathComponent }
            #expect(main?.exists == true)
            #expect(main?.excludedFromBackup == true)
            #expect(report.allExistingExcludedFromBackup)
            #expect(report.holds)
        }
    }

    @Test func protectedFileURLsCoverDbAndSidecars() throws {
        try withTempDatabase { url in
            let names = GrdbDatabaseFactory.protectedFileURLs(for: url).map(\.lastPathComponent)
            let base = url.lastPathComponent
            #expect(names == [base, base + "-wal", base + "-shm", base + "-journal"])
        }
    }

    @Test func assertionReportsAbsentSidecarsAsNonblocking() throws {
        try withTempDatabase { url in
            _ = try GrdbDatabaseFactory.open(at: url)
            let report = DataProtectionAssertion.assert(databaseURL: url)
            // A -journal sidecar typically does not exist under WAL mode; it must not break
            // the claim (absent files are vacuously fine).
            let journal = report.states.first { $0.fileName.hasSuffix("-journal") }
            #expect(journal?.exists == false)
            #expect(report.holds)
        }
    }

    @Test func assertionFlagsAFileThatIsNotExcluded() throws {
        try withTempDatabase { url in
            // Create a bare file WITHOUT excluding it; the assertion must report holds == false.
            try Data([0x00]).write(to: url)
            let report = DataProtectionAssertion.assert(databaseURL: url)
            #expect(report.allExistingExcludedFromBackup == false)
            #expect(report.holds == false)
        }
    }
}
