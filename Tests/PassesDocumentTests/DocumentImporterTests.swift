import Foundation
import PassesCore
import PassesPDFCore
import Testing

@testable import PassesDocument

// MARK: - Shared fixtures + seams (also used by DocumentImporterSourceReadTests)

let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
let pdfBytes = Data("%PDF-1.7\n%binary".utf8)
let webpBytes = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8) + Data([9, 9])
let secretPayload = "M1DOE/JANE       EABC123 SFOJFK"
let fixedWallClockMs: Int64 = 1_700_000_000_000

/// Call-recording seams with benign defaults; each test overrides only the
/// arm it exercises (Android's importer() helper).
final class Seams: @unchecked Sendable {
    let lock = NSLock()
    var pdfCalls: [(bytes: Data, label: String)] = []
    var imageCalls: [(bytes: Data, maxPx: Int)] = []
    var extractCalls: [Data] = []
    var persisted: [DocumentPersist] = []
    var telemetry: [String] = []

    var pdfResult: PDFImportResult = .rejected(kind: .notAPdf)
    var imageOutcome = ImageDecodeOutcome.decoded(
        thumbnailBytes: Data([0xAA]), widthPx: 800, heightPx: 600)
    var extractResult = BarcodeDecodeResult.noBarcodeFound
    var persistError: (any Error)?

    func record(_ line: String) {
        lock.lock()
        telemetry.append(line)
        lock.unlock()
    }
}

struct RecordingGuard: ImageImportTelemetryGuard {
    let seams: Seams
    func onImportStarted() { seams.record("started") }
    func onImportSucceeded(event: ImageImportSucceededEvent) {
        seams.record("ok:\(event.format):\(event.widthPx):\(event.heightPx)")
    }
    func onImportFailed(event: ImageImportFailedEvent) {
        seams.record("failed:\(event.outcome)")
    }
}

func makeImporter(
    _ seams: Seams, maxBytes: Int = Int(PDFImportConfig.defaultMaxBytes)
) -> DefaultDocumentImporter {
    var config = DocumentImportConfig()
    config.maxBytes = maxBytes
    config.imageTelemetryGuard = RecordingGuard(seams: seams)
    return DefaultDocumentImporter(
        config: config,
        pdfImport: { bytes, label, persist in
            seams.lock.withLock { seams.pdfCalls.append((bytes, label)) }
            if case .imported = seams.pdfResult {
                try await persist(label, bytes, 3, Data([0xBB]), [])
            }
            return seams.pdfResult
        },
        imageDecode: { bytes, maxPx in
            seams.lock.withLock { seams.imageCalls.append((bytes, maxPx)) }
            return seams.imageOutcome
        },
        barcodeExtract: { bytes in
            seams.lock.withLock { seams.extractCalls.append(bytes) }
            return seams.extractResult
        },
        now: { 0 },
        wallClock: { fixedWallClockMs },
        idGenerator: { "fixed-id" }
    )
}

func persistRecorder(_ seams: Seams) -> @Sendable (DocumentPersist) async throws -> Void {
    { value in
        if let error = seams.persistError { throw error }
        seams.lock.withLock { seams.persisted.append(value) }
    }
}

/// The sniff-and-branch import orchestration (mirror of Android
/// `DocumentImporterTest`, ios-dts.3): magic routing, per-backend rejection
/// mapping, the composite second decode over the SAME once-read bytes, the
/// confirmBarcode hook contract, the exactly-once persist guarantee, and the
/// payload-free degrade taxonomy at the persist seam.
@Suite("Document importer")
struct DocumentImporterTests {

    // MARK: - Branch routing

    @Test func pdfMagicRoutesToThePdfBackendAndForwardsOriginalBytesToPersist() async throws {
        let seams = Seams()
        seams.pdfResult = .imported(
            doc: PDFDocument(
                id: PDFDocumentId("p"), displayLabel: "Doc", byteCount: 16, pageCount: 3,
                importedAtEpochMs: 1))
        let result = try await makeImporter(seams).import(
            source: .data(pdfBytes), displayLabel: "Doc",
            persist: persistRecorder(seams))

        guard case .importedPdf = result else {
            Issue.record("expected importedPdf, got \(result)")
            return
        }
        #expect(seams.pdfCalls.first?.bytes == pdfBytes)
        #expect(seams.pdfCalls.first?.label == "Doc")
        guard case .pdf(let label, let bytes, let thumb, let pageCount, _) = seams.persisted.first
        else {
            Issue.record("expected pdf persist, got \(seams.persisted)")
            return
        }
        #expect(label == "Doc")
        #expect(bytes == pdfBytes)
        #expect(thumb == Data([0xBB]))
        #expect(pageCount == 3)
        #expect(seams.imageCalls.isEmpty)
    }

    @Test func pdfBackendStorageHandoffFailureHoistsToTheSharedArm() async throws {
        let seams = Seams()
        seams.pdfResult = .rejected(kind: .storageHandoffFailed)
        let result = try await makeImporter(seams).import(
            source: .data(pdfBytes), displayLabel: "D", persist: persistRecorder(seams))
        guard case .storageHandoffFailed = result else {
            Issue.record("expected storageHandoffFailed, got \(result)")
            return
        }
    }

    @Test func pdfBackendOtherRejectionMapsToPdfRejectedWithTheSameKind() async throws {
        let seams = Seams()
        seams.pdfResult = .rejected(kind: .rendererFailed)
        let result = try await makeImporter(seams).import(
            source: .data(pdfBytes), displayLabel: "D", persist: persistRecorder(seams))
        guard case .pdfRejected(let kind) = result else {
            Issue.record("expected pdfRejected, got \(result)")
            return
        }
        #expect(kind == .rendererFailed)
    }

    @Test func imageMagicPersistsOriginalBytesWithDimensions() async throws {
        let seams = Seams()
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "Pic", persist: persistRecorder(seams))

        guard case .importedImage(let doc) = result else {
            Issue.record("expected importedImage, got \(result)")
            return
        }
        #expect(doc.widthPx == 800)
        #expect(doc.heightPx == 600)
        #expect(doc.byteCount == Int64(pngBytes.count))
        #expect(doc.importedAtEpochMs == fixedWallClockMs)
        #expect(doc.id.value == "fixed-id")
        #expect(seams.imageCalls.first?.maxPx == DocumentImportConfig.defaultMaxImageDecodePx)
        guard
            case .image(let label, let bytes, _, let format, let width, let height, let extraction) =
                seams.persisted.first
        else {
            Issue.record("expected image persist, got \(seams.persisted)")
            return
        }
        #expect(label == "Pic")
        #expect(bytes == pngBytes)
        #expect(format == .png)
        #expect(width == 800)
        #expect(height == 600)
        #expect(extraction == .notAttempted)
        #expect(seams.telemetry == ["started", "ok:png:800:600"])
    }

    @Test func unrecognizedBytesReturnUnrecognizedAndTouchNoBackend() async throws {
        let seams = Seams()
        let result = try await makeImporter(seams).import(
            source: .data(Data([1, 2, 3, 4, 5, 6, 7, 8])), displayLabel: "X",
            persist: persistRecorder(seams))
        guard case .unrecognized = result else {
            Issue.record("expected unrecognized, got \(result)")
            return
        }
        #expect(seams.pdfCalls.isEmpty)
        #expect(seams.imageCalls.isEmpty)
        #expect(seams.telemetry.isEmpty)
    }

    /// The §7 term: webp is enforced-unreachable AT THE SNIFF — the bytes never
    /// touch a codec (the image seam is not called), rejecting before any decode.
    @Test func webpSniffsButIsRejectedBeforeAnyDecode() async throws {
        let seams = Seams()
        let result = try await makeImporter(seams).import(
            source: .data(webpBytes), displayLabel: "W",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        guard case .imageRejected(let kind) = result else {
            Issue.record("expected imageRejected, got \(result)")
            return
        }
        #expect(kind == .notAnImage)
        #expect(seams.imageCalls.isEmpty)
        #expect(seams.extractCalls.isEmpty)
        #expect(seams.persisted.isEmpty)
        #expect(seams.telemetry == ["started", "failed:decode"])
    }

    // MARK: - Failure mapping + telemetry

    @Test func imageDecodeRejectionMapsToImageRejectedAndEmitsDecodeTelemetry() async throws {
        let seams = Seams()
        seams.imageOutcome = .rejected(.dimensionsTooLarge)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P", persist: persistRecorder(seams))
        guard case .imageRejected(let kind) = result else {
            Issue.record("expected imageRejected, got \(result)")
            return
        }
        #expect(kind == .dimensionsTooLarge)
        #expect(seams.persisted.isEmpty)
        #expect(seams.telemetry == ["started", "failed:decode"])
    }

    @Test func imagePersistFailureHoistsToStorageHandoffAndEmitsStorageTelemetry() async throws {
        struct Boom: Error {}
        let seams = Seams()
        seams.persistError = Boom()
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P", persist: persistRecorder(seams))
        guard case .storageHandoffFailed = result else {
            Issue.record("expected storageHandoffFailed, got \(result)")
            return
        }
        #expect(seams.telemetry == ["started", "failed:storageHandoff"])
    }

    // MARK: - Composite (wpass-8lu mirror)

    @Test func imageWithBarcodeRoutesToCompositeAndPersistsPayloadAndFormat() async throws {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: "LOYAL-42", format: .qr)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "Card",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))

        guard case .importedBarcodedImage(let doc) = result else {
            Issue.record("expected composite, got \(result)")
            return
        }
        #expect(doc.barcodePayload == "LOYAL-42")
        #expect(doc.barcodeFormat == .qr)
        #expect(doc.widthPx == 800)
        #expect(doc.byteCount == Int64(pngBytes.count))
        // The barcode seam saw the SAME once-read bytes the image seam did.
        #expect(seams.extractCalls.first == pngBytes)
        #expect(seams.imageCalls.first?.bytes == pngBytes)
        guard
            case .barcodedImage(_, let bytes, _, let format, _, _, let payload, let symbology) =
                seams.persisted.first
        else {
            Issue.record("expected barcodedImage persist, got \(seams.persisted)")
            return
        }
        #expect(bytes == pngBytes)
        #expect(format == .png)
        #expect(payload == "LOYAL-42")
        #expect(symbology == .qr)
    }

    @Test func imageWithNoBarcodeDegradesToPlainImage() async throws {
        let seams = Seams()
        seams.extractResult = .noBarcodeFound
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        #expect(seams.persisted.first?.imageExtraction == .noCodeFound)
    }

    @Test func barcodeExtractionFailureDegradesToPlainImageRatherThanFailingImport() async throws {
        let seams = Seams()
        seams.extractResult = .decodeFailed(reason: .imageDecodeFailed)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        #expect(seams.persisted.first?.imageExtraction == .failed(reason: .imageDecodeFailed))
    }

    // MARK: - Degrade-reason distinctness (wpass-pl7.5 mirror)

    @Test func timedOutAndOversizeExtractionsProduceDistinguishableReasonsAtTheSeam() async throws {
        let timedOut = await persistedImageExtraction(for: .decodeTimedOut)
        let oversize = await persistedImageExtraction(for: .imageTooLarge)
        #expect(timedOut == .failed(reason: .decodeTimedOut))
        #expect(oversize == .failed(reason: .imageTooLarge))
        #expect(timedOut != oversize)
        #expect(timedOut != .noCodeFound)
    }

    @Test func everyDecodeFailureReasonReachesTheSeamVerbatim() async throws {
        for reason in DecodeFailureReason.allCases {
            let extraction = await persistedImageExtraction(for: reason)
            #expect(extraction == .failed(reason: reason), "reason \(reason) was folded")
        }
    }

    @Test func aDeclinedReadDegradesToAPlainImageNamingItselfAndCarryingNoPayload() async throws {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: secretPayload, format: .pdf417)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in false }, persist: persistRecorder(seams))
        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        let persisted = try #require(seams.persisted.first)
        #expect(persisted.imageExtraction == .declined)
        // Structural PII lock: the degrade seam never carries the payload (a BCBP
        // payload holds passenger name + PNR).
        #expect(!String(describing: persisted).contains(secretPayload))
    }

    // MARK: - Hook contract

    @Test func withoutAConfirmHookExtractionIsSkippedAndTheResultIsAPlainImage() async throws {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: "WOULD-BE-FOUND", format: .qr)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P", persist: persistRecorder(seams))
        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        #expect(seams.extractCalls.isEmpty, "no hook means extraction never runs")
        #expect(seams.persisted.first?.imageExtraction == .notAttempted)
    }

    @Test func confirmHookThrowingNonCancellationDegradesToPlainImage() async throws {
        struct ConfirmUiCrashed: Error {}
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: "X", format: .qr)
        let result = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in throw ConfirmUiCrashed() },
            persist: persistRecorder(seams))
        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        #expect(seams.persisted.first?.imageExtraction == .declined)
    }

    @Test func confirmHookCancellationPropagatesOutOfImportAndPersistsNothing() async {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: "X", format: .qr)
        do {
            _ = try await makeImporter(seams).import(
                source: .data(pngBytes), displayLabel: "P",
                confirmBarcode: { _, _ in throw CancellationError() },
                persist: persistRecorder(seams))
            Issue.record("cancellation must propagate")
        } catch is CancellationError {
            #expect(seams.persisted.isEmpty)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func confirmHookSeesTheDecodedPayloadBeforePersist() async throws {
        let seams = Seams()
        seams.extractResult = .decodedBarcode(payload: "SEEN-FIRST", format: .ean13)
        nonisolated(unsafe) var seen: (String, ScannableFormat)?
        nonisolated(unsafe) var persistedBeforeHook = false
        _ = try await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { payload, format in
                seen = (payload, format)
                persistedBeforeHook = !seams.persisted.isEmpty
                return true
            },
            persist: persistRecorder(seams))
        #expect(seen?.0 == "SEEN-FIRST")
        #expect(seen?.1 == .ean13)
        #expect(!persistedBeforeHook, "the hook fires BEFORE persist")
    }

    @Test func pdfWithEmbeddedBytesNeverRunsBarcodeExtraction() async throws {
        let seams = Seams()
        seams.pdfResult = .rejected(kind: .rendererFailed)
        _ = try await makeImporter(seams).import(
            source: .data(pdfBytes), displayLabel: "D",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        #expect(seams.extractCalls.isEmpty)
    }

    // MARK: - Helpers

    private func persistedImageExtraction(
        for reason: DecodeFailureReason
    ) async -> BarcodeExtractionOutcome? {
        let seams = Seams()
        seams.extractResult = .decodeFailed(reason: reason)
        _ = try? await makeImporter(seams).import(
            source: .data(pngBytes), displayLabel: "P",
            confirmBarcode: { _, _ in true }, persist: persistRecorder(seams))
        return seams.persisted.first?.imageExtraction
    }
}

extension DocumentPersist {
    /// The image arm's extraction outcome, for assertions.
    fileprivate var imageExtraction: BarcodeExtractionOutcome? {
        if case .image(_, _, _, _, _, _, let extraction) = self { return extraction }
        return nil
    }
}
