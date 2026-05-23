import Foundation
import Testing
import PassesPDFCore

@testable import PassesPDF

/// Behavioural coverage for ``DefaultPDFImporter``. Each test pins one rule
/// the importer promises in its doc comments. Mirrors Android's
/// `PdfImporterTest`:
///
///  - Header sniff short-circuits before the renderer session connects.
///  - Size cap fail-fast: never reads more than `maxBytes + 1` bytes.
///  - Every ``PassesPDFCore/DocumentRejectedKind`` from the renderer rounds
///    back through `import`.
///  - Session close runs in every outcome (success / each rejection / persist
///    throw).
///  - `persist` is invoked exactly once on success, never on rejection.
///  - Telemetry: `onImportFailed` fires on every rejection; `onImportStarted`
///    fires before any work; `onImportSucceeded` fires only on success.
///
/// The Android SDK-gate (`UnsupportedAndroidVersion`) and the non-content-URI
/// scheme test are intentionally omitted: iOS has no equivalent OS-version
/// gate inside the importer, and there is no `ContentResolver` to spoof a
/// `file://` URI on. The other test shapes port over directly.
@Suite("PDFImporter")
struct PDFImporterTests {

    @Test func headerSniffShortCircuitsBeforeConnectingSession() async throws {
        let nonPDF = Data("Not a PDF at all".utf8)
        let factory = RecordingSessionFactory()
        let importer = makeTestImporter(sessionFactory: factory)

        let result = try await importer.import(
            source: .data(nonPDF),
            displayLabel: "spoofed.pdf",
            persist: { _, _, _, _ in
                Issue.record("persist must not be invoked when header sniff fails")
            }
        )

        #expect(result == .rejected(kind: .notAPdf))
        #expect(factory.connectCalls == 0)
    }

    @Test func shorterThanHeaderRejectsAsNotAPDF() async throws {
        let tiny = Data("%PDF".utf8)
        let factory = RecordingSessionFactory()
        let importer = makeTestImporter(sessionFactory: factory)

        let result = try await importer.import(
            source: .data(tiny),
            displayLabel: "tiny.pdf",
            persist: { _, _, _, _ in Issue.record("persist must not run") }
        )

        #expect(result == .rejected(kind: .notAPdf))
        #expect(factory.connectCalls == 0)
    }

    @Test func oversizedSourceFailsFastBeforeFullDrain() async throws {
        let cap: Int64 = 8
        let cfg = PDFImportConfig(maxBytes: cap)
        let factory = RecordingSessionFactory()
        // 10 bytes of plausible PDF prefix + filler — exceeds the cap of 8.
        let oversized = Data("%PDF-1.4XX".utf8)
        let importer = makeTestImporter(config: cfg, sessionFactory: factory)

        let result = try await importer.import(
            source: .data(oversized),
            displayLabel: "big.pdf",
            persist: { _, _, _, _ in Issue.record("persist must not run for oversized") }
        )

        #expect(result == .rejected(kind: .oversizedAtImport))
        #expect(factory.connectCalls == 0)
    }

    @Test func probeRejectionRoundTripsThroughImport() async throws {
        let arms: [DocumentRejectedKind] = [.encrypted, .tooManyPages, .rendererFailed]
        for kind in arms {
            let factory = RecordingSessionFactory(
                binder: StaticBinder(probeResult: .rejected(kind: kind))
            )
            let result = try await makeTestImporter(sessionFactory: factory).import(
                source: .data(TestFixtures.validPDFBytes),
                displayLabel: "x.pdf",
                persist: { _, _, _, _ in
                    Issue.record("persist must not run on probe rejection")
                }
            )
            #expect(result == .rejected(kind: kind))
            #expect(factory.connectCalls == 1)
            #expect(factory.lastSession?.closed == true)
        }
    }

    @Test func renderRejectionRoundTripsThroughImport() async throws {
        for kind in [DocumentRejectedKind.rendererFailed] {
            let factory = RecordingSessionFactory(
                binder: StaticBinder(
                    probeResult: .ok(pageCount: 3),
                    renderResult: .rejected(kind: kind)
                )
            )
            let result = try await makeTestImporter(sessionFactory: factory).import(
                source: .data(TestFixtures.validPDFBytes),
                displayLabel: "x.pdf",
                persist: { _, _, _, _ in
                    Issue.record("persist must not run on render rejection")
                }
            )
            #expect(result == .rejected(kind: kind))
            #expect(factory.lastSession?.closed == true)
        }
    }

    @Test func successPathInvokesPersistExactlyOnceAndReturnsImported() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 4),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )
        let persists = PersistRecorder()
        let result = try await makeTestImporter(sessionFactory: factory).import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "boarding.pdf",
            persist: { label, bytes, pages, thumb in
                persists.append(label: label, byteSize: bytes.count, pages: pages, thumbSize: thumb.count)
            }
        )

        guard case .imported(let doc) = result else {
            Issue.record("Expected .imported, got \(result)")
            return
        }
        #expect(doc.displayLabel == "boarding.pdf")
        #expect(doc.pageCount == 4)
        #expect(doc.byteCount == Int64(TestFixtures.validPDFBytes.count))
        let recorded = persists.snapshot
        #expect(recorded.count == 1)
        #expect(recorded.first?.label == "boarding.pdf")
        #expect(recorded.first?.byteSize == TestFixtures.validPDFBytes.count)
        #expect(recorded.first?.pages == 4)
        #expect((recorded.first?.thumbSize ?? 0) > 0)
        #expect(factory.lastSession?.closed == true)
    }

    @Test func persistThrowFoldsToStorageHandoffFailedAndCloses() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 2),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )

        let result = try await makeTestImporter(sessionFactory: factory).import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "x.pdf",
            persist: { _, _, _, _ in
                throw NSError(domain: "downstream-storage", code: -1)
            }
        )

        #expect(result == .rejected(kind: .storageHandoffFailed))
        #expect(factory.lastSession?.closed == true)
    }

    @Test func encoderThrowFoldsToEncoderFailedAndCloses() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 2),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )

        let result = try await makeTestImporter(
            sessionFactory: factory,
            thumbnailEncoder: ThrowingThumbnailEncoder()
        ).import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "x.pdf",
            persist: { _, _, _, _ in
                Issue.record("persist must not run on encoder failure")
            }
        )

        #expect(result == .rejected(kind: .encoderFailed))
        #expect(factory.lastSession?.closed == true)
    }

    @Test func persistCancellationPropagatesAndPreservesStructuredConcurrency() async {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 1),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )

        var thrown: Error?
        do {
            _ = try await makeTestImporter(sessionFactory: factory).import(
                source: .data(TestFixtures.validPDFBytes),
                displayLabel: "x.pdf",
                persist: { _, _, _, _ in throw CancellationError() }
            )
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(factory.lastSession?.closed == true)
    }

    @Test func encoderCancellationPropagatesAndPreservesStructuredConcurrency() async {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 1),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )

        var thrown: Error?
        do {
            _ = try await makeTestImporter(
                sessionFactory: factory,
                thumbnailEncoder: CancellingThumbnailEncoder()
            ).import(
                source: .data(TestFixtures.validPDFBytes),
                displayLabel: "x.pdf",
                persist: { _, _, _, _ in }
            )
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(factory.lastSession?.closed == true)
    }

    @Test func nonFileURLSourceRejectsAsNotAPDFWithoutConnecting() async throws {
        let factory = RecordingSessionFactory()
        // http:// is the canonical escape-hatch shape the file-URL allowlist
        // closes: a future contributor could otherwise quietly fetch remote
        // bytes through this entry.
        let httpURL = URL(string: "https://example.com/x.pdf")!

        let result = try await makeTestImporter(sessionFactory: factory).import(
            source: .fileURL(httpURL),
            displayLabel: "x.pdf",
            persist: { _, _, _, _ in
                Issue.record("persist must not run for non-file scheme")
            }
        )

        #expect(result == .rejected(kind: .notAPdf))
        #expect(factory.connectCalls == 0)
    }

    @Test func closeRunsOnEveryRejectionAfterSuccessfulConnect() async throws {
        let arms: [DocumentRejectedKind] = [.encrypted, .tooManyPages, .rendererFailed]
        for kind in arms {
            let factory = RecordingSessionFactory(
                binder: StaticBinder(probeResult: .rejected(kind: kind))
            )
            _ = try await makeTestImporter(sessionFactory: factory).import(
                source: .data(TestFixtures.validPDFBytes),
                displayLabel: "x.pdf",
                persist: { _, _, _, _ in }
            )
            #expect(factory.lastSession?.closed == true)
        }
    }

    @Test func telemetryFiresStartAndSuccessOnHappyPath() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 1),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )
        let telemetry = RecordingTelemetry()
        let cfg = PDFImportConfig(telemetryGuard: telemetry)

        _ = try await makeTestImporter(config: cfg, sessionFactory: factory).import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "x.pdf",
            persist: { _, _, _, _ in }
        )

        #expect(telemetry.events == ["started", "succeeded:1"])
    }

    @Test func telemetryFiresStartedThenFailedOnPostStartRejection() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(probeResult: .rejected(kind: .encrypted))
        )
        let telemetry = RecordingTelemetry()
        let cfg = PDFImportConfig(telemetryGuard: telemetry)

        _ = try await makeTestImporter(config: cfg, sessionFactory: factory).import(
            source: .data(TestFixtures.validPDFBytes),
            displayLabel: "x.pdf",
            persist: { _, _, _, _ in }
        )

        #expect(telemetry.events == ["started", "failed:encrypted"])
    }

    @Test func fileURLSourceDrainsThroughFileHandle() async throws {
        let factory = RecordingSessionFactory(
            binder: StaticBinder(
                probeResult: .ok(pageCount: 1),
                renderResult: .ok(
                    pixels: TestFixtures.defaultThumbPixelBuffer(),
                    widthPx: TestFixtures.defaultThumbW,
                    heightPx: TestFixtures.defaultThumbH,
                    pageAspect: 1
                )
            )
        )
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt-test-\(UUID().uuidString).pdf")
        try TestFixtures.validPDFBytes.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let persists = PersistRecorder()
        let result = try await makeTestImporter(sessionFactory: factory).import(
            source: .fileURL(tmpURL),
            displayLabel: "from-url.pdf",
            persist: { _, bytes, _, _ in
                persists.append(label: "", byteSize: bytes.count, pages: 0, thumbSize: 0)
            }
        )

        if case .imported = result {} else {
            Issue.record("Expected .imported, got \(result)")
        }
        #expect(persists.snapshot.first?.byteSize == TestFixtures.validPDFBytes.count)
    }
}

/// Records persist arguments for inspection from tests; lock-protected so
/// the closure can be `@Sendable` without requiring an actor.
final class PersistRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let label: String
        let byteSize: Int
        let pages: Int
        let thumbSize: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(label: String, byteSize: Int, pages: Int, thumbSize: Int) {
        syncLocked(lock) {
            entries.append(Entry(label: label, byteSize: byteSize, pages: pages, thumbSize: thumbSize))
        }
    }

    var snapshot: [Entry] {
        syncLocked(lock) { entries }
    }
}
