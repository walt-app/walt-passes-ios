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

    @Test func oversizePdfDataRejectsAsThePdfOversizeArmWithTelemetry() async throws {
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
        // Same events the PDF backend would have emitted for its own oversize.
        #expect(seams.telemetry == ["pdf-started", "pdf-failed:oversizedAtImport"])
    }

    /// Over-cap webp reports the same arm its under-cap path does — never a
    /// codec, never a misleading oversize on a container the lane refuses.
    @Test func oversizeWebpRejectsAsNotAnImage() async throws {
        let seams = Seams()
        var contents = webpBytes
        contents.append(Data(repeating: 0x55, count: 200))
        let result = try await makeImporter(seams, maxBytes: 64).import(
            source: .data(contents), displayLabel: "W", persist: persistRecorder(seams))
        guard case .imageRejected(.notAnImage) = result else {
            Issue.record("expected notAnImage, got \(result)")
            return
        }
        #expect(seams.imageCalls.isEmpty && seams.extractCalls.isEmpty)
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

    /// A FIFO would block at open() forever; the regular-file gate rejects it
    /// INSTANTLY (never parking a reader thread), folding to unrecognized.
    @Test func fifoSourceIsRefusedByTheRegularFileGate() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_import_fifo_\(UUID().uuidString)").path
        try #require(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }

        let seams = Seams()
        let result = try await makeImporter(seams).import(
            source: .fileURL(URL(fileURLWithPath: path)), displayLabel: "F",
            persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized for a FIFO, got \(result)")
            return
        }
        #expect(seams.persisted.isEmpty)
    }

    // MARK: - The bounded wait primitive

    /// A read that outlives the deadline resolves the caller with the timeout
    /// value; the operation's own (later) result is dropped.
    @Test func deadlineResolvesTheCallerWhileTheReadRunsOn() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let value = await withSourceReadDeadline(
            .milliseconds(50), timeoutValue: "timed-out",
            slots: SourceReadSlots(capacity: 1)
        ) {
            gate.wait()
            return "completed"
        }
        #expect(value == "timed-out")
    }

    /// Past the slot ceiling a submission is REFUSED — resolved immediately with
    /// the timeout value, running nothing (the decode banks' refusal shape) —
    /// and a released slot admits the next read.
    @Test func aFullSlotBankRefusesImmediatelyAndReleasesAdmitTheNext() async {
        let slots = SourceReadSlots(capacity: 1)
        let holder = DispatchSemaphore(value: 0)
        let started = Flag()
        let held = Task {
            await withSourceReadDeadline(.seconds(5), timeoutValue: "held-timeout", slots: slots) {
                started.set()
                holder.wait()  // reader thread, not an async context
                return "held-done"
            }
        }
        // The slot is claimed before the reader thread starts, so once the
        // operation signals, the bank is definitely full.
        while !started.isSet { await Task.yield() }
        let refused = await withSourceReadDeadline(
            .seconds(5), timeoutValue: "refused", slots: slots
        ) {
            "must-not-run"
        }
        #expect(refused == "refused")
        holder.signal()
        let heldValue = await held.value
        #expect(heldValue == "held-done")
        // The slot releases on the reader thread just AFTER the resolve; wait
        // for it before proving a freed bank admits the next read.
        while !slots.claim() { await Task.yield() }
        slots.release()
        let after = await withSourceReadDeadline(
            .seconds(5), timeoutValue: "after-timeout", slots: slots
        ) {
            "after-ran"
        }
        #expect(after == "after-ran")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Cancellation

    /// The bounded waits return values rather than throwing, so cancellation is
    /// surfaced before persist: an abandoned import stores nothing.
    @Test func aCancelledImportPersistsNothing() async {
        let seams = Seams()
        let task = Task {
            try await makeImporter(seams).import(
                source: .data(pngBytes), displayLabel: "P",
                confirmBarcode: nil, persist: persistRecorder(seams))
        }
        task.cancel()
        do {
            _ = try await task.value
            // A benign race: the import may complete before the cancel lands.
        } catch is CancellationError {
            #expect(seams.persisted.isEmpty)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
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
        // D4 pin: the label is the caller's, verbatim — never payload-derived.
        #expect(persisted.label == "P")
        #expect(doc.displayLabel == "P")
    }
}
