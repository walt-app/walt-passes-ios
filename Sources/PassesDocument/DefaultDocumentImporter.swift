import CoreGraphics
import Foundation
import ImageIO
import PassesBarcode
import PassesCore
import PassesImage
import PassesPDF
import PassesPDFCore
import UniformTypeIdentifiers

/// Production factory. The concrete importer is package-private so the
/// backend seams stay off the public surface (sibling of `makePDFImporter`).
public func makeDocumentImporter(
    config: DocumentImportConfig = DocumentImportConfig()
) -> any DocumentImporter {
    let pdfImporter = makePDFImporter(config: config.pdfConfig)
    // NO config argument, deliberately: the §7 retained-lane allowlist and caps
    // are the defaults, and a call-site config would be one keystroke from
    // widening them (pinned by PassesDocumentGuardTests).
    let imageDecoder = makeBoundedImageDecoder()
    let barcodeDecoder = VisionBarcodeImageDecoder()
    return DefaultDocumentImporter(
        config: config,
        pdfImport: { bytes, label, persist in
            try await pdfImporter.import(
                source: .data(bytes), displayLabel: label,
                persist: { label, pdfBytes, pageCount, thumbnailBytes, pageRasters in
                    try await persist(label, pdfBytes, pageCount, thumbnailBytes, pageRasters)
                })
        },
        imageDecode: { bytes, maxPx in
            // The raster is Walt-produced (already decoded and bounded), so the
            // in-process PNG encode never runs a codec over hostile bytes.
            let result = await imageDecoder.decode(
                source: .data(bytes), maxWidthPx: maxPx, maxHeightPx: maxPx)
            switch result {
            case .rejected(let kind):
                return .rejected(kind)
            case .ok(let raster):
                guard let thumbnail = encodePng(raster.image) else {
                    return .rejected(.decodeFailed)
                }
                return .decoded(
                    thumbnailBytes: thumbnail, widthPx: raster.widthPx, heightPx: raster.heightPx)
            }
        },
        barcodeExtract: { bytes in
            // The composite second decode: the SAME once-read bytes, handed to
            // the bounded barcode read lane (§7: two bounded decodes per
            // composite import, Android's own two-sandbox parity).
            await barcodeDecoder.decode(source: .data(bytes))
        },
        now: { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
        wallClock: { Int64(Date().timeIntervalSince1970 * 1000) },
        idGenerator: { UUID().uuidString }
    )
}

/// The pdf backend's persist shape, adapted onto `DocumentPersist.pdf`.
typealias PdfPersistAdapter =
    @Sendable (
        _ label: String, _ pdfBytes: Data, _ pageCount: Int, _ thumbnailBytes: Data,
        _ pageRasters: [StoredPageRaster]
    ) async throws -> Void

/// The image seam's collapsed value — the orchestrator never sees a raster
/// handle, only the encoded Walt-produced thumbnail and the dimensions.
enum ImageDecodeOutcome: Sendable {
    case decoded(thumbnailBytes: Data, widthPx: Int, heightPx: Int)
    case rejected(ImageDecodeRejectedKind)
}

/// Internal so the importer never threads a raw `BarcodeDecodeResult` past the
/// seam; only the distilled `(payload, format)` and the payload-free
/// `BarcodeExtractionOutcome` cross it.
enum BarcodeExtraction {
    case confirmed(payload: String, format: ScannableFormat)
    case degraded(BarcodeExtractionOutcome)
}

struct DefaultDocumentImporter: DocumentImporter {
    let config: DocumentImportConfig
    let pdfImport: @Sendable (Data, String, @escaping PdfPersistAdapter) async throws -> PDFImportResult
    let imageDecode: @Sendable (Data, Int) async -> ImageDecodeOutcome
    let barcodeExtract: @Sendable (Data) async -> BarcodeDecodeResult
    /// Monotonic millis — telemetry durations ONLY.
    let now: @Sendable () -> Int64
    /// Epoch millis — `importedAtEpochMs` ONLY (the monotonic clock cannot serve
    /// here; it is not epoch time).
    let wallClock: @Sendable () -> Int64
    let idGenerator: @Sendable () -> String

    func `import`(
        source: DocumentImportSource,
        displayLabel: String,
        confirmBarcode: (@Sendable (String, ScannableFormat) async throws -> Bool)?,
        persist: @escaping @Sendable (DocumentPersist) async throws -> Void
    ) async throws -> DocumentImportResult {
        // One bounded read closes the offset-corruption hazard a peek-then-reopen
        // would open: whatever a backend receives is materialized from this exact
        // buffer, not a second read of the source.
        let startedAt = now()
        let bytes: Data
        switch await readBounded(source) {
        case .unavailable:
            return .unrecognized
        case .oversized(let prefix):
            return rejectOversized(prefix: prefix, durationMillis: now() - startedAt)
        case .bytes(let read):
            bytes = read
        }
        if isPDFHeader(bytes) {
            return try await importPdf(bytes: bytes, displayLabel: displayLabel, persist: persist)
        }
        if let format = sniffImageFormat(bytes) {
            return try await importImage(
                bytes: bytes, format: format, displayLabel: displayLabel,
                confirmBarcode: confirmBarcode, persist: persist)
        }
        return .unrecognized
    }

    /// An over-cap source is named HERE, from the truncated prefix's sniff, and
    /// never reaches a backend, a codec, or `persist`. Delegating oversize to
    /// the backends (Android's shape) silently persists TRUNCATED bytes as the
    /// original whenever a backend cap is raised above `maxBytes` — the buffer
    /// clears the widened gate at `maxBytes + 1` and imports corrupt. Each arm
    /// emits the same guard events its backend would have for its own oversize.
    private func rejectOversized(prefix: Data, durationMillis: Int64) -> DocumentImportResult {
        if isPDFHeader(prefix) {
            let pdfGuard = config.pdfConfig.telemetryGuard
            pdfGuard.onImportStarted()
            pdfGuard.onImportFailed(
                event: DocumentImportFailedEvent(
                    outcome: .oversizedAtImport, durationMillis: durationMillis))
            return .pdfRejected(.oversizedAtImport)
        }
        if let format = sniffImageFormat(prefix) {
            let guardHook = config.imageTelemetryGuard
            guardHook.onImportStarted()
            guardHook.onImportFailed(
                event: ImageImportFailedEvent(outcome: .decode, durationMillis: durationMillis))
            // An over-cap webp reports the same arm its under-cap path does.
            return .imageRejected(format == .webp ? .notAnImage : .oversizedAtImport)
        }
        return .unrecognized
    }

    // MARK: - PDF branch

    private func importPdf(
        bytes: Data, displayLabel: String,
        persist: @escaping @Sendable (DocumentPersist) async throws -> Void
    ) async throws -> DocumentImportResult {
        let adapter: PdfPersistAdapter = { label, pdfBytes, pageCount, thumbnailBytes, pageRasters in
            try await persist(
                .pdf(
                    label: label, bytes: pdfBytes, thumbnailBytes: thumbnailBytes,
                    pageCount: pageCount, pageRasters: pageRasters))
        }
        let result = try await pdfImport(bytes, displayLabel, adapter)
        switch result {
        case .imported(let doc):
            return .importedPdf(doc)
        case .rejected(let kind):
            // The one translated kind, so a storage failure reads identically
            // across document kinds; everything else rides through verbatim.
            return kind == .storageHandoffFailed ? .storageHandoffFailed : .pdfRejected(kind)
        }
    }

    // MARK: - Image branch

    private func importImage(
        bytes: Data, format: ImageFormat, displayLabel: String,
        confirmBarcode: (@Sendable (String, ScannableFormat) async throws -> Bool)?,
        persist: @escaping @Sendable (DocumentPersist) async throws -> Void
    ) async throws -> DocumentImportResult {
        let startedAt = now()
        let guardHook = config.imageTelemetryGuard
        guardHook.onImportStarted()

        // §7 term: webp is enforced-unreachable AT THE SNIFF — rejected here so
        // the bytes never touch a codec (the retained lane admits JPEG/PNG only;
        // the value stays in the vocabulary for schema parity).
        if format == .webp {
            guardHook.onImportFailed(
                event: ImageImportFailedEvent(outcome: .decode, durationMillis: now() - startedAt))
            return .imageRejected(.notAnImage)
        }

        let decoded: (thumbnailBytes: Data, widthPx: Int, heightPx: Int)
        switch await imageDecode(bytes, config.maxImageDecodePx) {
        case .rejected(let kind):
            guardHook.onImportFailed(
                event: ImageImportFailedEvent(outcome: .decode, durationMillis: now() - startedAt))
            return .imageRejected(kind)
        case .decoded(let thumbnailBytes, let widthPx, let heightPx):
            decoded = (thumbnailBytes, widthPx, heightPx)
        }

        // Resolved BEFORE persist so nothing is stored until the consumer's
        // confirm step has run.
        let extraction = try await extractConfirmedBarcode(
            bytes: bytes, confirmBarcode: confirmBarcode)

        let persistValue = buildPersist(
            extraction: extraction, displayLabel: displayLabel, bytes: bytes,
            decoded: decoded, format: format)
        do {
            // The bounded waits above return values rather than throwing, so a
            // cancellation raised during them is surfaced here — nothing is
            // stored for an import the user has already abandoned.
            try Task.checkCancellation()
            try await persist(persistValue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guardHook.onImportFailed(
                event: ImageImportFailedEvent(outcome: .storageHandoff, durationMillis: now() - startedAt))
            return .storageHandoffFailed
        }

        let byteCount = Int64(bytes.count)
        guardHook.onImportSucceeded(
            event: ImageImportSucceededEvent(
                byteCount: byteCount, format: format, widthPx: decoded.widthPx,
                heightPx: decoded.heightPx, durationMillis: now() - startedAt))
        return buildImportedResult(
            extraction: extraction, displayLabel: displayLabel, byteCount: byteCount,
            decoded: decoded)
    }

    /// The hook contract in one place: nil hook means extraction never runs
    /// (`notAttempted` — the absence of a code is unknown, not observed); the
    /// hook is only called when a code was actually decoded; cancellation
    /// propagates; any other throw is a decline.
    private func extractConfirmedBarcode(
        bytes: Data,
        confirmBarcode: (@Sendable (String, ScannableFormat) async throws -> Bool)?
    ) async throws -> BarcodeExtraction {
        guard let confirmBarcode else { return .degraded(.notAttempted) }
        let payload: String
        let format: ScannableFormat
        switch await barcodeExtract(bytes) {
        case .noBarcodeFound:
            return .degraded(.noCodeFound)
        case .decodeFailed(let reason):
            return .degraded(.failed(reason: reason))
        case .decodedBarcode(let decodedPayload, let decodedFormat):
            (payload, format) = (decodedPayload, decodedFormat)
        }
        let confirmed: Bool
        do {
            confirmed = try await confirmBarcode(payload, format)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            confirmed = false
        }
        return confirmed
            ? .confirmed(payload: payload, format: format)
            : .degraded(.declined)
    }

    private func buildPersist(
        extraction: BarcodeExtraction, displayLabel: String, bytes: Data,
        decoded: (thumbnailBytes: Data, widthPx: Int, heightPx: Int), format: ImageFormat
    ) -> DocumentPersist {
        switch extraction {
        case .confirmed(let payload, let symbology):
            return .barcodedImage(
                label: displayLabel, bytes: bytes, thumbnailBytes: decoded.thumbnailBytes,
                format: format, widthPx: decoded.widthPx, heightPx: decoded.heightPx,
                barcodePayload: payload, barcodeFormat: symbology)
        case .degraded(let outcome):
            return .image(
                label: displayLabel, bytes: bytes, thumbnailBytes: decoded.thumbnailBytes,
                format: format, widthPx: decoded.widthPx, heightPx: decoded.heightPx,
                barcodeExtraction: outcome)
        }
    }

    /// Id and importedAt are stamped POST-persist; the consumer's storage layer
    /// assigns its own row identity — this id names the returned model only.
    private func buildImportedResult(
        extraction: BarcodeExtraction, displayLabel: String, byteCount: Int64,
        decoded: (thumbnailBytes: Data, widthPx: Int, heightPx: Int)
    ) -> DocumentImportResult {
        switch extraction {
        case .confirmed(let payload, let symbology):
            return .importedBarcodedImage(
                BarcodedImageDocument(
                    id: BarcodedImageDocumentId(idGenerator()), displayLabel: displayLabel,
                    byteCount: byteCount, widthPx: decoded.widthPx, heightPx: decoded.heightPx,
                    barcodePayload: payload, barcodeFormat: symbology,
                    importedAtEpochMs: wallClock()))
        case .degraded:
            return .importedImage(
                ImageDocument(
                    id: ImageDocumentId(idGenerator()), displayLabel: displayLabel,
                    byteCount: byteCount, widthPx: decoded.widthPx, heightPx: decoded.heightPx,
                    importedAtEpochMs: wallClock()))
        }
    }

    // MARK: - Bounded read

    /// Read the source once, at most `maxBytes + 1` bytes — one past the cap so
    /// an over-cap source is OBSERVED (and rejected by `rejectOversized`)
    /// without this importer ever buffering the whole oversized file.
    /// `unavailable` (→ unrecognized) only when the source cannot be read at
    /// all. The `.fileURL` read runs off the cooperative pool under
    /// `config.sourceReadTimeout` — see `withSourceReadDeadline`.
    private func readBounded(_ source: DocumentImportSource) async -> BoundedSourceRead {
        let maxBytes = config.maxBytes
        switch source {
        case .data(let data):
            return data.count > maxBytes
                ? .oversized(prefix: data.prefix(maxBytes + 1)) : .bytes(data)
        case .fileURL(let url):
            // The arm's name is a claim `URL` cannot enforce (the sibling
            // importers' guard); a non-file scheme is refused before any open.
            guard url.isFileURL else { return .unavailable }
            return await withSourceReadDeadline(
                config.sourceReadTimeout, timeoutValue: .unavailable
            ) {
                Self.blockingFileRead(url: url, maxBytes: maxBytes)
            }
        }
    }

    private static func blockingFileRead(url: URL, maxBytes: Int) -> BoundedSourceRead {
        // O_NONBLOCK so a FIFO cannot park the thread at open(); only a regular
        // file proceeds (a FIFO or device rejects instantly, never holding a
        // read slot). O_NONBLOCK is then cleared: regular-file reads block
        // normally under the deadline.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return .unavailable }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return .unavailable
        }
        _ = fcntl(fd, F_SETFL, 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        // Saturating: a Int.max cap cannot trap the +1 into a crash.
        let ceiling = maxBytes < Int.max ? maxBytes + 1 : Int.max
        let chunkSize = 64 * 1024
        var bytes = Data()
        do {
            while bytes.count < ceiling {
                guard
                    let chunk = try handle.read(upToCount: min(chunkSize, ceiling - bytes.count)),
                    !chunk.isEmpty
                else { break }
                bytes.append(chunk)
            }
        } catch {
            return .unavailable
        }
        return bytes.count > maxBytes ? .oversized(prefix: bytes) : .bytes(bytes)
    }
}

/// PNG-encode a Walt-produced raster (never hostile bytes) for the thumbnail.
private func encodePng(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
}
