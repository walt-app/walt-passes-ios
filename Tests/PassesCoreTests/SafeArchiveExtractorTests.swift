import Foundation
import Testing

@testable import PassesCore

@Suite("SafeArchiveExtractor")
struct SafeArchiveExtractorTests {

    private func extract(_ bytes: [UInt8], config: ParserConfig = ParserConfig()) -> ExtractResult {
        extractSafely(.bytes(Data(bytes)), config: config)
    }

    private func entries(_ result: ExtractResult) -> [(name: String, bytes: [UInt8])]? {
        if case .success(let e, _) = result { return e }
        return nil
    }

    @Test func extractsEntriesInOrder() {
        let archive = ZipBuilder.build([
            ZipBuilder.File("pass.json", "{}"),
            ZipBuilder.File("icon.png", [1, 2, 3]),
        ])
        let e = entries(extract(archive))
        #expect(e?.map(\.name) == ["pass.json", "icon.png"])
        #expect(e?[0].bytes == [UInt8]("{}".utf8))
    }

    @Test func nonZipMagicRejected() {
        if case .failure(let reason) = extract([0x42, 0x42, 0x42, 0x42]) {
            #expect(reason == .notAZipArchive)
        } else {
            Issue.record("expected failure")
        }
    }

    @Test func emptyInputRejected() {
        if case .failure(let reason) = extract([]) {
            #expect(reason == .notAZipArchive)
        } else {
            Issue.record("expected failure")
        }
    }

    @Test func emptyZipSucceedsWithNoEntries() {
        let e = entries(extract(ZipBuilder.empty()))
        #expect(e?.isEmpty == true)
    }

    @Test func archiveSizeCapTrips() {
        let archive = ZipBuilder.build([ZipBuilder.File("pass.json", "{}")])
        let config = ParserConfig(maxArchiveBytes: 4)
        if case .failure(let reason) = extract(archive, config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .archiveSize))
        } else {
            Issue.record("expected archive-size failure")
        }
    }

    @Test func entryCountCapTrips() {
        let files = (0..<5).map { ZipBuilder.File("file\($0).json", "{}") }
        let config = ParserConfig(maxEntries: 3)
        if case .failure(let reason) = extract(ZipBuilder.build(files), config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .entryCount))
        } else {
            Issue.record("expected entry-count failure")
        }
    }

    @Test func entrySizeCapTrips() {
        let big = [UInt8](repeating: 0x41, count: 100)
        let archive = ZipBuilder.build([ZipBuilder.File("pass.json", big)])
        let config = ParserConfig(maxEntryBytes: 10)
        if case .failure(let reason) = extract(archive, config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .entrySize))
        } else {
            Issue.record("expected entry-size failure")
        }
    }

    /// Nine 4 MiB entries each fit the per-entry cap and the archive stays a few KiB, but they
    /// inflate to 36 MiB, past the 32 MiB default budget.
    @Test func manyEntriesUnderTheEntryCapTripTheInflatedSizeLimitAtDefaults() {
        let zeros = [UInt8](repeating: 0, count: Int(ParserConfig.defaultMaxEntryBytes))
        let files = (0..<9).map { ZipBuilder.File("file\($0).png", zeros, deflated: true) }
        let archive = ZipBuilder.build(files)
        #expect(Int64(archive.count) < ParserConfig.defaultMaxArchiveBytes)
        if case .failure(let reason) = extract(archive) {
            #expect(reason == .resourceLimitExceeded(limit: .inflatedSize))
        } else {
            Issue.record("expected inflated-size failure")
        }
    }

    @Test func inflatedTotalExactlyAtTheLimitIsAccepted() {
        let files = (0..<4).map { ZipBuilder.File("file\($0).png", [UInt8](repeating: 1, count: 25)) }
        let e = entries(extract(ZipBuilder.build(files), config: ParserConfig(maxInflatedBytes: 100)))
        #expect(e?.count == 4)
    }

    @Test func inflatedTotalOneByteOverTheLimitIsRejected() {
        let files = (0..<4).map { ZipBuilder.File("file\($0).png", [UInt8](repeating: 1, count: 25)) }
        let config = ParserConfig(maxInflatedBytes: 99)
        if case .failure(let reason) = extract(ZipBuilder.build(files), config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .inflatedSize))
        } else {
            Issue.record("expected inflated-size failure")
        }
    }

    /// Directory entries are discarded after reading, but their payload is still inflated, so it
    /// pays into the budget (Android drains them through the same budget).
    @Test func directoryEntryPayloadsAreChargedAgainstTheInflatedSizeLimit() {
        let archive = ZipBuilder.build([
            ZipBuilder.File("en.lproj/", [UInt8](repeating: 1, count: 60)),
            ZipBuilder.File("pass.json", [UInt8](repeating: 1, count: 60)),
        ])
        let config = ParserConfig(maxInflatedBytes: 100)
        if case .failure(let reason) = extract(archive, config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .inflatedSize))
        } else {
            Issue.record("expected inflated-size failure")
        }
    }

    /// One entry over the per-entry cap keeps its own, more specific reason.
    @Test func entrySizeIsReportedBeforeTheInflatedTotal() {
        let archive = ZipBuilder.build([ZipBuilder.File("pass.json", [UInt8](repeating: 1, count: 100))])
        let config = ParserConfig(maxEntryBytes: 50, maxInflatedBytes: 50)
        if case .failure(let reason) = extract(archive, config: config) {
            #expect(reason == .resourceLimitExceeded(limit: .entrySize))
        } else {
            Issue.record("expected entry-size failure")
        }
    }

    @Test func pathTraversalRejected() {
        let archive = ZipBuilder.build([ZipBuilder.File("../evil.json", "{}")])
        if case .failure(let reason) = extract(archive) {
            #expect(reason == .notAZipArchive)
        } else {
            Issue.record("expected path-traversal failure")
        }
    }

    @Test func absolutePathRejected() {
        let archive = ZipBuilder.build([ZipBuilder.File("/etc/passwd.json", "{}")])
        if case .failure = extract(archive) {} else { Issue.record("expected failure") }
    }

    @Test func backslashRejected() {
        let archive = ZipBuilder.build([ZipBuilder.File("a\\b.json", "{}")])
        if case .failure = extract(archive) {} else { Issue.record("expected failure") }
    }

    @Test func disallowedExtensionRejected() {
        let archive = ZipBuilder.build([ZipBuilder.File("evil.sh", "{}")])
        if case .failure(let reason) = extract(archive) {
            #expect(reason == .notAZipArchive)
        } else {
            Issue.record("expected disallowed-extension failure")
        }
    }

    @Test func signatureAllowedOnlyAtRoot() {
        // Root "signature" is allowed.
        let ok = ZipBuilder.build([ZipBuilder.File("signature", [1, 2, 3])])
        #expect(entries(extract(ok))?.first?.name == "signature")
        // Nested "signature" is a disallowed-extension entry.
        let nested = ZipBuilder.build([ZipBuilder.File("nested/signature", [1, 2, 3])])
        if case .failure = extract(nested) {} else { Issue.record("expected nested-signature failure") }
    }

    @Test func duplicateEntryRejected() {
        let archive = ZipBuilder.build([
            ZipBuilder.File("pass.json", "{}"),
            ZipBuilder.File("pass.json", "{}"),
        ])
        if case .failure(let reason) = extract(archive) {
            #expect(reason == .notAZipArchive)
        } else {
            Issue.record("expected duplicate failure")
        }
    }

    @Test func directoryEntriesSkipped() {
        let archive = ZipBuilder.build([
            ZipBuilder.File("en.lproj/", []),
            ZipBuilder.File("en.lproj/pass.strings", "\"k\"=\"v\";"),
        ])
        let e = entries(extract(archive))
        #expect(e?.map(\.name) == ["en.lproj/pass.strings"])
    }
}
