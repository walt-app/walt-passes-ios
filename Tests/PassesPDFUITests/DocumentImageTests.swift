import CoreGraphics
import Foundation
import PassesImage
import PassesPDFCore
import Testing

@testable import PassesPDFUI

/// Locks the public API shape of the image facade (the `rememberDocumentImage`
/// analogue) — the image-arm sibling of `PDFThumbnailSurfaceTests`. The shape
/// IS the trust contract: leaking image metadata or EXIF through this surface
/// requires adding a field to ``DocumentImageState``, which breaks a test here.
@Suite("DocumentImage surface")
struct DocumentImageSurfaceTests {

    @Test func documentImageStateHasExactlyThreeArms() {
        // Loading, rendered (image + sourceAspect), failed (kind) — the
        // Android `DocumentImageState` sealed set. A fourth arm is a
        // deliberate trust-shape change reviewed against ADR 0005 D4.
        let states: [DocumentImageState] = [
            .loading,
            .failed(kind: .decodeFailed),
        ]
        for state in states {
            switch state {
            case .loading: break
            case .rendered: Issue.record("loading/failed should not be rendered")
            case .failed: break
            }
        }
    }

    @Test func documentImageStateFailedKindIsImageDecodeRejectedKind() {
        // A String / Error / message field on the `.failed` arm would be a
        // PII leak by the same rule DocumentTelemetryGuard enforces.
        let state: DocumentImageState = .failed(kind: .dimensionsTooLarge)
        if case .failed(let kind) = state {
            #expect(kind == ImageDecodeRejectedKind.dimensionsTooLarge)
        } else {
            Issue.record("expected .failed arm")
        }
    }
}

/// Behavior of ``DocumentImageViewModel`` against a fake bounded decoder —
/// the facade's lifecycle contract (decode-once, restart-cancels, stop-on-
/// disappear) without a view host.
@MainActor
@Suite("DocumentImage view model")
struct DocumentImageViewModelTests {

    @Test func okDecodePublishesRenderedWithTheSourceAspect() async throws {
        let decoder = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 2, heightPx: 1, sourceAspect: 2.0)))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 1200)
        let state = try await Self.settledState(of: viewModel)
        guard case .rendered(_, let sourceAspect) = state else {
            Issue.record("expected rendered, got \(state)")
            return
        }
        #expect(sourceAspect == 2.0)
        // The single inline budget bounds both axes (aspect-fit never upscales).
        #expect(decoder.calls.first?.maxWidthPx == 1200)
        #expect(decoder.calls.first?.maxHeightPx == 1200)
        #expect(decoder.calls.count == 1, "an image decodes once — no pager, no cache")
    }

    @Test func rejectedDecodePublishesFailedWithTheKindVerbatim() async throws {
        let decoder = FakeBoundedImageDecoder(result: .rejected(.dimensionsTooLarge))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 1200)
        let state = try await Self.settledState(of: viewModel)
        guard case .failed(let kind) = state else {
            Issue.record("expected failed, got \(state)")
            return
        }
        #expect(kind == .dimensionsTooLarge)
    }

    @Test func theCompositeArmRendersThroughTheSameFacade() async throws {
        // wpass-8lu: documentId is the supertype, so the image half of a
        // composite decodes through the identical path — nothing here can
        // tell the arms apart or reach the barcode half.
        let decoder = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 1, heightPx: 1, sourceAspect: 1.0)))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: BarcodedImageDocumentId("b1"), source: .data(Data([1])),
            decoder: decoder, maxPixelSize: 640)
        let state = try await Self.settledState(of: viewModel)
        guard case .rendered = state else {
            Issue.record("expected rendered, got \(state)")
            return
        }
    }

    @Test func stopBeforeTheDecodeCompletesNeverPublishes() async throws {
        let decoder = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 1, heightPx: 1, sourceAspect: 1.0)))
        decoder.gate = true
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        viewModel.stop()
        decoder.releaseGate()
        // Give the (cancelled) task a chance to run to completion.
        for _ in 0..<50 { await Task.yield() }
        guard case .loading = viewModel.state else {
            Issue.record("a stopped facade must not publish, got \(viewModel.state)")
            return
        }
    }

    @Test func aChangedKeySupersedesThePriorDecode() async throws {
        let first = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 1, heightPx: 1, sourceAspect: 1.0)))
        first.gate = true
        let second = FakeBoundedImageDecoder(result: .rejected(.decodeFailed))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: ImageDocumentId("doc-a"), source: .data(Data([1])), decoder: first,
            maxPixelSize: 100)
        viewModel.start(
            documentId: ImageDocumentId("doc-b"), source: .data(Data([2])), decoder: second,
            maxPixelSize: 100)
        let state = try await Self.settledState(of: viewModel)
        first.releaseGate()
        for _ in 0..<50 { await Task.yield() }
        // The superseded first decode (rendered) must not overwrite the
        // second's outcome (failed).
        guard case .failed = state, case .failed = viewModel.state else {
            Issue.record("expected the second decode's outcome, got \(viewModel.state)")
            return
        }
    }

    @Test func anUnchangedKeyNeverRestartsALiveOrSettledDecode() async throws {
        // The produceState-key semantics: SwiftUI may re-fire the view's task
        // (reappear at a stable identity) — the same document must not decode
        // twice.
        let decoder = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 1, heightPx: 1, sourceAspect: 1.0)))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        _ = try await Self.settledState(of: viewModel)
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        for _ in 0..<50 { await Task.yield() }
        #expect(decoder.calls.count == 1, "an unchanged key decoded more than once")
    }

    @Test func stopReleasesThePixelsAndASameKeyRestartReDecodes() async throws {
        // stop() is the dispose analogue (pixels released); a reappearance at
        // the same key re-decodes rather than showing a released handle.
        let decoder = FakeBoundedImageDecoder(
            result: .ok(Self.raster(widthPx: 1, heightPx: 1, sourceAspect: 1.0)))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        _ = try await Self.settledState(of: viewModel)
        viewModel.stop()
        guard case .loading = viewModel.state else {
            Issue.record("stop() must release the rendered handle")
            return
        }
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 100)
        _ = try await Self.settledState(of: viewModel)
        #expect(decoder.calls.count == 2)
    }

    @Test func theViewKeysItsDecodeTaskOnTheDocumentId() throws {
        // The facade's key semantics only fire if the VIEW re-invokes start on
        // a document change; source-pinned because SwiftUI lifecycle cannot be
        // driven from a unit test.
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI/DocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            text.contains(".task(id: documentId.value)"),
            "ImageDocumentView must key its decode task on the document id")
    }

    @Test func foldMapsOkAndRejectedVerbatim() {
        // The fold seam directly (its reason to be a seam): aspect preserved
        // on ok, kind verbatim on rejected, telemetry deliberately untouched.
        let ok = foldDecodedImage(
            .ok(Self.raster(widthPx: 3, heightPx: 1, sourceAspect: 3.0)),
            telemetry: DocumentTelemetryGuardNoOp.shared)
        guard case .rendered(let decoded) = ok else {
            Issue.record("expected rendered fold")
            return
        }
        #expect(decoded.sourceAspect == 3.0)
        let rejected = foldDecodedImage(
            .rejected(.oversizedAtImport), telemetry: DocumentTelemetryGuardNoOp.shared)
        guard case .failed(.oversizedAtImport) = rejected else {
            Issue.record("expected failed fold with the kind verbatim")
            return
        }
    }

    @Test func aNonPositiveRequestIsClampedToOnePixel() async throws {
        let decoder = FakeBoundedImageDecoder(result: .rejected(.decodeFailed))
        let viewModel = DocumentImageViewModel()
        viewModel.start(
            documentId: Self.imageId, source: .data(Data([1])), decoder: decoder,
            maxPixelSize: 0)
        _ = try await Self.settledState(of: viewModel)
        #expect(decoder.calls.first?.maxWidthPx == 1)
    }

    // MARK: - Helpers

    private static let imageId = ImageDocumentId("i1")

    private static func raster(widthPx: Int, heightPx: Int, sourceAspect: Float) -> ImageRaster {
        let context = CGContext(
            data: nil, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ImageRaster(
            image: context.makeImage()!, widthPx: widthPx, heightPx: heightPx,
            sourceAspect: sourceAspect)
    }

    /// Poll until the facade leaves `.loading` (its publishes hop the main
    /// actor, so a bounded yield loop is deterministic enough here).
    private static func settledState(
        of viewModel: DocumentImageViewModel
    ) async throws -> DocumentImageState {
        for _ in 0..<2000 {
            if case .loading = viewModel.state {
                await Task.yield()
            } else {
                return viewModel.state
            }
        }
        throw SettleTimeout()
    }

    private struct SettleTimeout: Error {}
}

/// Call-recording fake decoder; `gate` holds the decode open until released
/// so cancellation ordering is deterministic.
private final class FakeBoundedImageDecoder: BoundedImageDecoder, @unchecked Sendable {
    struct Call {
        let maxWidthPx: Int
        let maxHeightPx: Int
    }

    private let lock = NSLock()
    private let result: ImageDecodeResult
    private var recorded: [Call] = []
    private var gateStream: AsyncStream<Void>.Continuation?
    var gate = false

    init(result: ImageDecodeResult) {
        self.result = result
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func releaseGate() {
        lock.lock()
        let continuation = gateStream
        lock.unlock()
        continuation?.finish()
    }

    func decode(
        source: ImageDecodeSource, maxWidthPx: Int, maxHeightPx: Int
    ) async -> ImageDecodeResult {
        if let stream = record(Call(maxWidthPx: maxWidthPx, maxHeightPx: maxHeightPx)) {
            for await _ in stream {}
        }
        return result
    }

    /// Synchronous half of `decode` (NSLock cannot be taken in an async
    /// context): records the call and, when gated, arms the hold-open stream.
    private func record(_ call: Call) -> AsyncStream<Void>? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        guard gate else { return nil }
        return AsyncStream<Void> { continuation in
            gateStream = continuation
        }
    }
}
