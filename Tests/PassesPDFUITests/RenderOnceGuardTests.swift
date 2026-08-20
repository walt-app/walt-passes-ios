import CoreGraphics
import Foundation
import ImageIO
import PassesPDFCore
import Testing
import UniformTypeIdentifiers

@testable import PassesPDFUI

/// The structural half of the ios-dts.16 render-once contract: the display
/// module must be INCAPABLE of parsing a document, not merely disciplined
/// about it. Two layers pin that:
///
///  1. `Package.swift` gives `PassesPDFUI` no `PassesPDF` dependency, so the
///     renderer seam does not resolve at compile time.
///  2. This source scan refuses any re-introduction path the dependency drop
///     alone would not catch — a direct `import PDFKit`, a `PDFDocument(data:`
///     construction via some future transitive route, or re-adding
///     `import PassesPDF`.
///
/// Mirrors the app repo's source-scanning guard pattern
/// (`UntrustedImageDecodeGuardTests` analogue, scoped to this module).
@Suite("Render-once guard")
struct RenderOnceGuardTests {

    @Test func passesPDFUISourcesCannotReachAPDFParser() throws {
        let sourcesDir = URL(fileURLWithPath: #filePath)  // .../Tests/PassesPDFUITests/RenderOnceGuardTests.swift
            .deletingLastPathComponent()  // Tests/PassesPDFUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/PassesPDFUI")
        let files = try #require(
            FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        )
        // `\b` keeps `import PassesPDFCore` legal while catching `import PassesPDF`
        // anywhere — including as a file's final unterminated line. Each needle is a
        // regex paired with a canary it must match: an invalid pattern (an unescaped
        // `(` once made one) silently never matches, hollowing out the guard.
        let forbidden: [(needle: String, canary: String)] = [
            (#"import\s+PassesPDF\b"#, "import PassesPDF"),
            ("import PDFKit", "import PDFKit"),
            (#"PDFDocument\(data"#, "PDFDocument(data: bytes)"),
            ("PDFRendererBinder", "let r: PDFRendererBinder"),
            ("CGPDFDocument", "CGPDFDocument(provider)"),
        ]
        for (needle, canary) in forbidden {
            #expect(
                canary.range(of: needle, options: .regularExpression) != nil,
                "dead guard needle (invalid regex or wrong shape): \(needle)"
            )
        }
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for (needle, _) in forbidden {
                #expect(
                    text.range(of: needle, options: .regularExpression) == nil,
                    "\(url.lastPathComponent) reintroduces a document-parse path: \(needle)"
                )
            }
        }
        #expect(scanned > 5, "source scan found too few files — wrong directory?")
    }

    /// The image lane's analogue of the parser scan (ios-dts.4): untrusted
    /// original image bytes entered this module with `imageSource`, and the
    /// ONLY sanctioned decode path for them is the §7 `BoundedImageDecoder`
    /// PROTOCOL, caller-supplied. Two rosters enforce that structurally:
    /// nothing in this module may construct a decoder (widening the §7 config
    /// is a composition-root decision), and the image-lane files may not reach
    /// ImageIO or the stored-raster inflate — `decodeStoredRaster`'s raw
    /// `CGImageSource` is safe ONLY for Walt-produced raster bytes, so routing
    /// an untrusted source into it would bypass every §7 cap.
    @Test func imageLaneCannotConstructADecoderOrReachImageIO() throws {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PassesPDFUI")
        let files = try #require(
            FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        )
        // Module-wide: the kernel never constructs a bounded decoder.
        let constructionNeedles = ["makeBoundedImageDecoder", "DefaultBoundedImageDecoder"]
        // Image-lane files: no ImageIO, no raw decode, no stored-raster inflate.
        let imageLaneFiles = [
            "DocumentView.swift", "DocumentImage.swift", "ImageRendering.swift",
            "FullScreenDocumentView.swift",
        ]
        let imageLaneNeedles = [
            "CGImageSource", "UIImage(", "CIImage(", "import ImageIO",
            "decodeStoredRaster(", "StoredPageRaster(",
        ]
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for needle in constructionNeedles {
                #expect(
                    !text.contains(needle),
                    "\(url.lastPathComponent) constructs a bounded decoder: \(needle)"
                )
            }
            if imageLaneFiles.contains(url.lastPathComponent) {
                for needle in imageLaneNeedles {
                    #expect(
                        !text.contains(needle),
                        "\(url.lastPathComponent) bypasses the bounded image lane: \(needle)"
                    )
                }
            }
        }
        #expect(scanned > 5, "source scan found too few files — wrong directory?")
    }
}

/// Behavior of the stored-raster load path in `PDFThumbnailViewModel`.
@MainActor
@Suite("Stored-raster page load")
struct StoredRasterLoadTests {

    private static let doc = PDFDocument(
        id: PDFDocumentId("doc-1"),
        displayLabel: "tax-2025.pdf",
        byteCount: 1024,
        pageCount: 1,
        importedAtEpochMs: 0
    )

    /// A real 2x3 PNG produced with ImageIO — the same encoder family the
    /// importer uses, so the decode-side test exercises genuine bytes.
    private static func tinyPng(width: Int = 2, height: Int = 3) -> Data {
        let bytesPerRow = width * 4
        let pixels = Data(repeating: 0xFF, count: bytesPerRow * height)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func storedRasterDecodesToRenderedState() async {
        let raster = StoredPageRaster(pngBytes: Self.tinyPng(), widthPx: 2, heightPx: 3)
        let viewModel = PDFThumbnailViewModel()
        viewModel.start(
            document: Self.doc, page: 0,
            source: StaticSource(raster: raster),
            context: ThumbnailRenderContext()
        )
        await settle(viewModel)
        guard case .rendered(_, let aspect) = viewModel.state else {
            Issue.record("expected rendered, got \(viewModel.state)")
            return
        }
        #expect(abs(aspect - 2.0 / 3.0) < 0.001)
    }

    @Test func missingRasterFailsClosed() async {
        let viewModel = PDFThumbnailViewModel()
        viewModel.start(
            document: Self.doc, page: 0,
            source: StaticSource(raster: nil),
            context: ThumbnailRenderContext()
        )
        await settle(viewModel)
        guard case .failed(let kind) = viewModel.state else {
            Issue.record("expected failed, got \(viewModel.state)")
            return
        }
        #expect(kind == .rendererFailed)
    }

    @Test func undecodableRasterFailsClosedAndReportsConsumerFailure() async {
        let telemetry = RecordingTelemetry()
        let raster = StoredPageRaster(pngBytes: Data([0x00, 0x01]), widthPx: 2, heightPx: 3)
        let viewModel = PDFThumbnailViewModel()
        viewModel.start(
            document: Self.doc, page: 0,
            source: StaticSource(raster: raster),
            context: ThumbnailRenderContext(telemetry: telemetry)
        )
        await settle(viewModel)
        guard case .failed = viewModel.state else {
            Issue.record("expected failed, got \(viewModel.state)")
            return
        }
        #expect(telemetry.consumerFailures == [.other])
    }

    @Test func decodeCapBoundsTheLongerSideAndNilDecodesFull() {
        // 8x12 stored PNG: capped at 6 the longer side lands at 6; nil keeps 12.
        let raster = StoredPageRaster(pngBytes: Self.tinyPng(width: 8, height: 12), widthPx: 8, heightPx: 12)
        let capped = decodeStoredRaster(raster, maxPixelSize: 6)
        #expect(capped != nil)
        if let capped {
            #expect(max(capped.cgImage.width, capped.cgImage.height) <= 6)
        }
        let full = decodeStoredRaster(raster)
        #expect(full?.cgImage.width == 8)
        #expect(full?.cgImage.height == 12)
    }

    @Test func inlineCapIsWellBelowTheStoredBudget() {
        // The inline pager must not pay the full-screen 4 MP decode per page.
        #expect(DocumentView.inlineMaxPixelSize <= 1200)
        #expect(DocumentView.inlineMaxPixelSize >= 600)
    }

    @Test func decodedRasterIsServedFromTheCacheOnRestart() async {
        let raster = StoredPageRaster(pngBytes: Self.tinyPng(), widthPx: 2, heightPx: 3)
        let cache = PDFThumbnailCache()
        let counting = CountingSource(raster: raster)
        let viewModel = PDFThumbnailViewModel()
        viewModel.start(
            document: Self.doc, page: 0, source: counting,
            context: ThumbnailRenderContext(cache: cache)
        )
        await settle(viewModel)
        viewModel.start(
            document: Self.doc, page: 0, source: counting,
            context: ThumbnailRenderContext(cache: cache)
        )
        await settle(viewModel)
        guard case .rendered = viewModel.state else {
            Issue.record("expected rendered")
            return
        }
        #expect(counting.calls == 1)
    }

    /// The load task hops actors per await (source read, detached decode); poll
    /// with short sleeps so every hop can run to completion deterministically.
    private func settle(_ viewModel: PDFThumbnailViewModel) async {
        for _ in 0..<200 {
            if case .loading = viewModel.state {
                try? await Task.sleep(for: .milliseconds(5))
            } else {
                return
            }
        }
    }
}

private struct StaticSource: DocumentPageSource {
    let raster: StoredPageRaster?
    func pageRaster(page: Int) async -> StoredPageRaster? { raster }
}

private final class CountingSource: DocumentPageSource, @unchecked Sendable {
    private let lock = NSLock()
    private let raster: StoredPageRaster?
    private var _calls = 0

    init(raster: StoredPageRaster?) {
        self.raster = raster
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func pageRaster(page: Int) async -> StoredPageRaster? {
        bump()
        return raster
    }

    // NSLock.lock() is unavailable from async contexts; hop through a sync helper.
    private func bump() {
        lock.lock()
        _calls += 1
        lock.unlock()
    }
}

private final class RecordingTelemetry: DocumentTelemetryGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var _consumerFailures: [ConsumerRenderFailure] = []

    var consumerFailures: [ConsumerRenderFailure] {
        lock.lock()
        defer { lock.unlock() }
        return _consumerFailures
    }

    func onImportStarted() {}
    func onImportSucceeded(event: DocumentImportSucceededEvent) {}
    func onImportFailed(event: DocumentImportFailedEvent) {}
    func onConsumerRenderFailed(reason: ConsumerRenderFailure) {
        lock.lock()
        _consumerFailures.append(reason)
        lock.unlock()
    }
}
