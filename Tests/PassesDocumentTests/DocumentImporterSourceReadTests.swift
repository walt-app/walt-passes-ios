import Foundation
import PassesCore
import PassesPDFCore
import Testing

@testable import PassesDocument

/// The single bounded source read: oversize named at the importer (truncated
/// bytes never reach a codec or persist), the off-pool `.fileURL` read and its
/// deadline, and the payload-redacting stringification of the composite values.
@Suite("Document importer source read")
struct DocumentImporterSourceReadTests {
    // MARK: - Bounded read + oversize

    /// The file read is bounded to maxBytes + 1 (never the whole bomb), and the
    /// over-cap source is rejected AT the importer as the sniffed kind's
    /// oversize arm: truncated bytes never reach a codec seam or persist.
    @Test func oversizeImageFileRejectsWithoutTouchingASeamOrPersist() async throws {
        let seams = Seams()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_import_\(UUID().uuidString).png")
        var contents = pngBytes
        contents.append(Data(repeating: 0x55, count: 200))
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await makeImporter(seams, maxBytes: 64).import(
            source: .fileURL(url), displayLabel: "F", persist: persistRecorder(seams))
        guard case .imageRejected(.oversizedAtImport) = result else {
            Issue.record("expected oversize rejection, got \(result)")
            return
        }
        #expect(seams.imageCalls.isEmpty && seams.extractCalls.isEmpty)
        #expect(seams.persisted.isEmpty)
        #expect(seams.telemetry == ["started", "failed:decode"])
    }

    @Test func oversizePdfDataRejectsAsThePdfOversizeArm() async throws {
        let seams = Seams()
        var contents = pdfBytes
        contents.append(Data(repeating: 0x55, count: 200))
        let result = try await makeImporter(seams, maxBytes: 64).import(
            source: .data(contents), displayLabel: "D", persist: persistRecorder(seams))
        guard case .pdfRejected(.oversizedAtImport) = result else {
            Issue.record("expected pdf oversize rejection, got \(result)")
            return
        }
        #expect(seams.pdfCalls.isEmpty && seams.persisted.isEmpty)
    }

    @Test func oversizeUnrecognizedBytesStayUnrecognized() async throws {
        let seams = Seams()
        let result = try await makeImporter(seams, maxBytes: 64).import(
            source: .data(Data(repeating: 0x42, count: 200)), displayLabel: "X",
            persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized, got \(result)")
            return
        }
    }

    @Test func unreadableFileSourceIsUnrecognized() async throws {
        let seams = Seams()
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).bin")
        let result = try await makeImporter(seams).import(
            source: .fileURL(missing), displayLabel: "F", persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized, got \(result)")
            return
        }
    }

    @Test func nonFileSchemeUrlIsRefusedBeforeAnyOpen() async throws {
        let seams = Seams()
        let remote = try #require(URL(string: "https://example.com/a.png"))
        let result = try await makeImporter(seams).import(
            source: .fileURL(remote), displayLabel: "F", persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized, got \(result)")
            return
        }
    }

    /// A stalled source (here a writer-less FIFO, which blocks at open) must not
    /// hang the caller: the bounded wait folds it to unrecognized at the
    /// deadline, and the read never occupies a cooperative-pool thread.
    @Test func stalledFileSourceFoldsToUnrecognizedAtTheDeadline() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_import_fifo_\(UUID().uuidString)").path
        try #require(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }

        let seams = Seams()
        var config = DocumentImportConfig()
        config.sourceReadTimeout = .milliseconds(80)
        config.imageTelemetryGuard = RecordingGuard(seams: seams)
        let importer = DefaultDocumentImporter(
            config: config,
            pdfImport: { _, _, _ in .rejected(kind: .notAPdf) },
            imageDecode: { _, _ in seams.imageOutcome },
            barcodeExtract: { _ in .noBarcodeFound },
            now: { 0 }, wallClock: { fixedWallClockMs }, idGenerator: { "fixed-id" }
        )
        let result = try await importer.import(
            source: .fileURL(URL(fileURLWithPath: path)), displayLabel: "F",
            persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized on a stalled read, got \(result)")
            return
        }
        #expect(seams.persisted.isEmpty)
    }

    // MARK: - Payload redaction

    /// The confirmed arm legitimately CARRIES the payload — but printing it must
    /// not leak it: both the persist value and the returned model redact.
    @Test func confirmedCompositeStringificationRedactsThePayload() async throws {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: secretPayload, format: .pdf417)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        let persisted = try #require(seams.persisted.first)
        #expect(!String(describing: persisted).contains(secretPayload))
        #expect(!String(reflecting: persisted).contains(secretPayload))
        guard case .importedBarcodedImage(let doc) = result else {
            Issue.record("expected composite, got \(result)")
            return
        }
        #expect(doc.barcodePayload == secretPayload, "the VALUE still carries it")
        #expect(!String(describing: doc).contains(secretPayload))
        #expect(!String(reflecting: doc).contains(secretPayload))
    }
}
