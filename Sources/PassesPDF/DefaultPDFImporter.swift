import Foundation
import PassesPDFCore

/// The orchestration sequence mirrors Android's `DefaultPdfImporter` step by
/// step, minus the SDK gate (no per-OS-version floor on iOS once the package
/// minimum is met) and the memfd allocation (PDFKit takes a `Data` buffer
/// directly):
///
///  1. Materialize the source to a bounded, in-memory byte buffer with a
///     fail-fast cap.
///  2. Header-sniff the first 8 bytes - before connecting the renderer
///     session.
///  3. Connect the renderer session, probe, render(page 0).
///  4. Encode the page-zero render to PNG.
///  5. Hand off to the consumer's `persist` callback.
///
/// Each step's rejection routes back into
/// ``PassesPDFCore/DocumentRejectedKind``; the renderer session is closed in
/// a `defer` regardless of outcome.
///
/// Rejection-arm routing keeps trust bands distinct:
///
///  - ``PassesPDFCore/DocumentRejectedKind/rendererFailed`` is reserved for
///    the connect -> probe -> render window. A spike here is the signal that
///    PDFKit may have refused a file.
///  - ``PassesPDFCore/DocumentRejectedKind/encoderFailed`` covers
///    post-render PNG encoding failures. A spike here is "the renderer
///    succeeded but the PNG path blew up."
///  - ``PassesPDFCore/DocumentRejectedKind/storageHandoffFailed`` is
///    reserved for `persist` throws. A spike here points the on-call at the
///    consumer's storage layer, not the renderer.
///
/// `CancellationError` is rethrown from the encode and persist wrap points so
/// a parent-scope cancel during import surfaces as cancellation, preserving
/// structured concurrency instead of silently converting cancellation into
/// an import rejection.
package final class DefaultPDFImporter: PDFImporter {
    /// Internal seams folded into one record so the initializer stays
    /// readable. Every field is independently overridable from tests;
    /// production callers never construct ``Deps`` directly because the
    /// public ``makePDFImporter(config:)`` factory builds
    /// ``DefaultPDFImporter`` with the production defaults.
    package struct Deps: Sendable {
        package let sessionFactory: any RendererSessionFactory
        package let thumbnailEncoder: any ThumbnailEncoder
        package let now: @Sendable () -> Int64
        package let idGenerator: @Sendable () -> String
        package let clockEpochMs: @Sendable () -> Int64

        package init(
            sessionFactory: any RendererSessionFactory = PDFKitRendererSessionFactory(),
            thumbnailEncoder: any ThumbnailEncoder = PNGThumbnailEncoder(),
            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
            clockEpochMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.sessionFactory = sessionFactory
            self.thumbnailEncoder = thumbnailEncoder
            self.now = now
            self.idGenerator = idGenerator
            self.clockEpochMs = clockEpochMs
        }
    }

    /// Thumbnail dimensions for the smoke render. 600 x 800 = 480 000 px,
    /// comfortably below the renderer's 4 MP cap, with an aspect ratio close
    /// to the 4:3 tile the document UI renders into.
    package static let thumbWidthPx: Int = 600
    package static let thumbHeightPx: Int = 800

    package static let headerBytes: Int = 8
    /// Read buffer for the materialization loop. 64 KiB matches a typical
    /// `InputStream.copyTo` default and keeps allocation overhead low.
    package static let copyBufferSize: Int = 64 * 1024

    private let config: PDFImportConfig
    private let deps: Deps

    package init(config: PDFImportConfig, deps: Deps = Deps()) {
        self.config = config
        self.deps = deps
    }

    public func `import`(
        source: PDFImportSource,
        displayLabel: String,
        persist: @Sendable (_ label: String, _ pdfBytes: Data, _ pageCount: Int, _ thumbnailBytes: Data) async throws -> Void
    ) async throws -> PDFImportResult {
        let startedAt = deps.now()
        config.telemetryGuard.onImportStarted()

        let bytes: Data
        switch materialize(source: source, startedAt: startedAt) {
        case .ok(let b):
            bytes = b
        case .reject(let result):
            return result
        }

        let session = await deps.sessionFactory.connect()
        defer { session.close() }
        return try await renderAndPersist(
            session: session,
            bytes: bytes,
            displayLabel: displayLabel,
            persist: persist,
            startedAt: startedAt
        )
    }

    // MARK: - Materialization

    private enum Materialized {
        case ok(Data)
        case reject(PDFImportResult)
    }

    private func materialize(source: PDFImportSource, startedAt: Int64) -> Materialized {
        let read: BoundedRead
        switch source {
        case .fileURL(let url):
            read = readBoundedURL(url, maxBytes: config.maxBytes)
        case .data(let data):
            read = readBoundedData(data, maxBytes: config.maxBytes)
        }
        let bytes: Data
        switch read {
        case .bytes(let b):
            bytes = b
        case .oversized:
            return .reject(rejectAndReport(.oversizedAtImport, startedAt: startedAt))
        case .sourceUnavailable:
            return .reject(rejectAndReport(.notAPdf, startedAt: startedAt))
        }
        let headerBytes = Self.headerBytes
        if bytes.count < headerBytes || !isPDFHeader(bytes.prefix(headerBytes)) {
            return .reject(rejectAndReport(.notAPdf, startedAt: startedAt))
        }
        return .ok(bytes)
    }

    private enum BoundedRead {
        case bytes(Data)
        case oversized
        case sourceUnavailable
    }

    private func readBoundedURL(_ url: URL, maxBytes: Int64) -> BoundedRead {
        guard url.isFileURL else { return .sourceUnavailable }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .sourceUnavailable
        }
        defer { try? handle.close() }
        let ceiling = maxBytes + 1
        var total: Int64 = 0
        var buffer = Data()
        while total < ceiling {
            let want = min(Int64(Self.copyBufferSize), ceiling - total)
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: Int(want)) else { break }
                chunk = read
            } catch {
                return .sourceUnavailable
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            total += Int64(chunk.count)
        }
        return total > maxBytes ? .oversized : .bytes(buffer)
    }

    private func readBoundedData(_ data: Data, maxBytes: Int64) -> BoundedRead {
        if Int64(data.count) > maxBytes {
            return .oversized
        }
        return .bytes(data)
    }

    // MARK: - Render + persist

    private func renderAndPersist(
        session: RendererSession,
        bytes: Data,
        displayLabel: String,
        persist: @Sendable (_ label: String, _ pdfBytes: Data, _ pageCount: Int, _ thumbnailBytes: Data) async throws -> Void,
        startedAt: Int64
    ) async throws -> PDFImportResult {
        let pages: Int
        switch await session.client.probe(pdf: bytes) {
        case .rejected(let kind):
            return rejectAndReport(kind, startedAt: startedAt)
        case .ok(let count):
            pages = count
        }

        let renderResult = await session.client.render(
            pdf: bytes,
            page: 0,
            widthPx: Self.thumbWidthPx,
            heightPx: Self.thumbHeightPx,
            sourceRect: .fullPage
        )
        switch renderResult {
        case .rejected(let kind):
            return rejectAndReport(kind, startedAt: startedAt)
        case .ok:
            break
        }

        let thumbnailBytes: Data
        do {
            thumbnailBytes = try deps.thumbnailEncoder.encode(render: renderResult)
        } catch is CancellationError {
            // CancellationError is part of structured concurrency: catching
            // it here would silently convert a parent-scope cancel into an
            // `encoderFailed` rejection, breaking the parent's "import was
            // cancelled" signal. Rethrow lets the cancellation propagate.
            throw CancellationError()
        } catch {
            return rejectAndReport(.encoderFailed, startedAt: startedAt)
        }

        do {
            try await persist(displayLabel, bytes, pages, thumbnailBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return rejectAndReport(.storageHandoffFailed, startedAt: startedAt)
        }

        let doc = PDFDocument(
            id: PDFDocumentId(deps.idGenerator()),
            displayLabel: displayLabel,
            byteCount: Int64(bytes.count),
            pageCount: pages,
            importedAtEpochMs: deps.clockEpochMs()
        )
        config.telemetryGuard.onImportSucceeded(
            event: DocumentImportSucceededEvent(
                byteCount: doc.byteCount,
                pageCount: doc.pageCount,
                durationMillis: deps.now() - startedAt
            )
        )
        return .imported(doc: doc)
    }

    private func rejectAndReport(
        _ kind: DocumentRejectedKind,
        startedAt: Int64
    ) -> PDFImportResult {
        config.telemetryGuard.onImportFailed(
            event: DocumentImportFailedEvent(
                outcome: kind,
                durationMillis: deps.now() - startedAt
            )
        )
        return .rejected(kind: kind)
    }
}
