import Foundation
import Testing

@testable import PassesPDFCore

/// Locks the public API surface of `PassesPDFCore`. There is no renderer or import
/// implementation yet (those land in the PassesPDF bead); these tests target two things:
///
///  1. Drift detection - every sum-type arm and enum value referenced by the import
///     contract is reachable from a test. Removing an arm fails compilation; adding one
///     without updating the `DocumentRejectedKind` enum fails compilation in consumer
///     `switch`es.
///  2. Default-policy locks - `PDFImportConfig` defaults encode ADR 0005 D7 (25 MB /
///     10 pages / 5 s); flipping a default is a deliberate, test-breaking change.
@Suite("PublicApiSurface")
struct PublicApiSurfaceTests {

    @Test func pdfImportConfigDefaultsMatchAdr0005D7() {
        let cfg = PDFImportConfig()
        #expect(cfg.maxBytes == 25 * 1024 * 1024)
        #expect(cfg.maxPages == 10)
        #expect(cfg.renderTimeoutMs == 5_000)
        #expect(PDFImportConfig.defaultMaxBytes == cfg.maxBytes)
        #expect(PDFImportConfig.defaultMaxPages == cfg.maxPages)
        #expect(PDFImportConfig.defaultRenderTimeoutMs == cfg.renderTimeoutMs)
    }

    @Test func pdfImportConfigDefaultGuardIsNoOp() {
        // The default guard is the singleton no-op. Exercise every method to confirm
        // it is wired and silent; the structural lock on shape lives in
        // `DocumentTelemetryGuardSurfaceTests`.
        let guard1 = PDFImportConfig().telemetryGuard
        guard1.onImportStarted()
        guard1.onImportSucceeded(
            event: DocumentImportSucceededEvent(byteCount: 0, pageCount: 0, durationMillis: 0)
        )
        guard1.onImportFailed(
            event: DocumentImportFailedEvent(outcome: .encrypted, durationMillis: 0)
        )
        guard1.onConsumerRenderFailed(reason: .outOfMemory)
    }

    @Test func documentRejectedKindHasExactlyTheEightListedArms() {
        let all: Set<DocumentRejectedKind> = [
            .oversizedAtImport,
            .notAPdf,
            .encrypted,
            .tooManyPages,
            .rendererFailed,
            .unsupportedAndroidVersion,
            .encoderFailed,
            .storageHandoffFailed,
        ]
        #expect(Set(DocumentRejectedKind.allCases) == all)
        #expect(DocumentRejectedKind.allCases.count == 8)
    }

    @Test func provenanceHasExactlyUserProvided() {
        #expect(Provenance.allCases == [.userProvided])
    }

    @Test func pdfImportResultArmsAreReachableViaSwitch() {
        let rejected: PDFImportResult = .rejected(kind: .encrypted)
        let branch: String
        switch rejected {
        case .imported: branch = "imported"
        case .rejected: branch = "rejected"
        }
        #expect(branch == "rejected")
    }

    @Test func pdfDocumentConstructorIsExercisedWithEveryShape() {
        let doc = PDFDocument(
            id: PDFDocumentId("doc-1"),
            displayLabel: "boarding-pass.pdf",
            byteCount: 1_234_567,
            pageCount: 3,
            importedAtEpochMs: 1_800_000_000_000,
            provenance: .userProvided
        )
        #expect(doc.id == PDFDocumentId("doc-1"))
        #expect(doc.provenance == .userProvided)
    }

    @Test func pdfDocumentDefaultProvenanceIsUserProvided() {
        let doc = PDFDocument(
            id: PDFDocumentId("doc-1"),
            displayLabel: "x",
            byteCount: 0,
            pageCount: 0,
            importedAtEpochMs: 0
        )
        #expect(doc.provenance == .userProvided)
    }

    @Test func documentTelemetryGuardNoOpAcceptsAllEventShapes() {
        let g: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
        g.onImportStarted()
        g.onImportSucceeded(
            event: DocumentImportSucceededEvent(byteCount: 12_345, pageCount: 4, durationMillis: 42)
        )
        g.onImportFailed(
            event: DocumentImportFailedEvent(outcome: .encrypted, durationMillis: 7)
        )
        g.onConsumerRenderFailed(reason: .outOfMemory)
        g.onConsumerRenderFailed(reason: .sharedMemoryUnavailable)
        g.onConsumerRenderFailed(reason: .dimensionMismatch)
        g.onConsumerRenderFailed(reason: .other)
    }

    @Test func consumerRenderFailureHasExactlyTheFourListedArms() {
        let all: Set<ConsumerRenderFailure> = [
            .outOfMemory,
            .sharedMemoryUnavailable,
            .dimensionMismatch,
            .other,
        ]
        #expect(Set(ConsumerRenderFailure.allCases) == all)
        #expect(ConsumerRenderFailure.allCases.count == 4)
    }

    /// Mirrors Android `documentTelemetryGuardEventsAreEnumsAndPrimitivesOnly`: an
    /// exhaustive behavioural exercise that pins every guard method against an
    /// enums-and-primitives-only shape. Adding a free-form `String`, `Data`, or `Error`
    /// parameter to any method below would fail to compile against this fixture.
    @Test func documentTelemetryGuardEventsAreEnumsAndPrimitivesOnly() {
        final class Recorder: @unchecked Sendable {
            var values: [String] = []
        }
        struct RecordingGuard: DocumentTelemetryGuard {
            let recorder: Recorder
            func onImportStarted() {
                recorder.values.append("started")
            }
            func onImportSucceeded(event: DocumentImportSucceededEvent) {
                recorder.values.append("ok:\(event.byteCount):\(event.pageCount):\(event.durationMillis)")
            }
            func onImportFailed(event: DocumentImportFailedEvent) {
                recorder.values.append("failed:\(event.outcome):\(event.durationMillis)")
            }
            func onConsumerRenderFailed(reason: ConsumerRenderFailure) {
                recorder.values.append("render:\(reason)")
            }
        }
        let recorder = Recorder()
        let g: DocumentTelemetryGuard = RecordingGuard(recorder: recorder)
        g.onImportStarted()
        g.onImportSucceeded(
            event: DocumentImportSucceededEvent(byteCount: 99, pageCount: 2, durationMillis: 11)
        )
        g.onImportFailed(
            event: DocumentImportFailedEvent(outcome: .tooManyPages, durationMillis: 3)
        )
        g.onConsumerRenderFailed(reason: .dimensionMismatch)

        #expect(
            recorder.values == [
                "started",
                "ok:99:2:11",
                "failed:tooManyPages:3",
                "render:dimensionMismatch",
            ])
    }
}
