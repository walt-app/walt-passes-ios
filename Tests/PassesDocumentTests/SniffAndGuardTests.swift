import Foundation
import PassesStorage
import Testing

@testable import PassesDocument

/// The magic-byte sniff (Android `ImageHeaderSniffer` mirror): every check is
/// anchored to byte 0 — searching for the magic elsewhere would let an attacker
/// prepend an arbitrary payload before the image data.
@Suite("Image header sniff")
struct ImageHeaderSnifferTests {

    @Test func pngSignatureSniffsAsPng() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])
        #expect(sniffImageFormat(png) == .png)
    }

    @Test func jpegSoiSniffsAsJpegWithoutCheckingByteThree() {
        // JFIF, EXIF and raw variants differ at byte 3; all must sniff.
        for fourth: UInt8 in [0xE0, 0xE1, 0xDB] {
            #expect(sniffImageFormat(Data([0xFF, 0xD8, 0xFF, fourth])) == .jpeg)
        }
    }

    @Test func webpRiffContainerSniffsAsWebpIgnoringTheChunkSize() {
        var webp = Data("RIFF".utf8)
        webp.append(Data([0xDE, 0xAD, 0xBE, 0xEF]))  // chunk size: intentionally skipped
        webp.append(Data("WEBP".utf8))
        #expect(sniffImageFormat(webp) == .webp)
    }

    @Test func prependedPayloadDefeatsTheSniff() {
        var prefixed = Data([0x00])
        prefixed.append(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(sniffImageFormat(prefixed) == nil)
    }

    @Test func shortAndForeignBuffersSniffAsNil() {
        #expect(sniffImageFormat(Data([0x89, 0x50])) == nil)
        #expect(sniffImageFormat(Data("GIF89a".utf8)) == nil)
        #expect(sniffImageFormat(Data()) == nil)
    }
}

/// Structural locks on the module's trust seams.
@Suite("PassesDocument guards")
struct PassesDocumentGuardTests {

    /// The telemetry events carry only enums, counts and durations — no String,
    /// no Data, no dictionary (the load-bearing PII control, mirror of the
    /// DocumentTelemetryGuard discipline). Checked structurally via a RECURSIVE
    /// mirror walk, so a nested struct or an associated `String` on a failure
    /// arm is caught, not just a top-level field.
    @Test func telemetryEventShapesCarryNoStringsOrBytes() {
        let events: [Any] = [
            ImageImportSucceededEvent(
                byteCount: 1, format: .png, widthPx: 2, heightPx: 3, durationMillis: 4),
            ImageImportFailedEvent(outcome: .decode, durationMillis: 1),
            ImageImportFailedEvent(outcome: .storageHandoff, durationMillis: 1),
        ]
        for event in events {
            expectNoFreeFormCarrier(in: event, path: "\(type(of: event))")
        }
    }

    private func expectNoFreeFormCarrier(in value: Any, path: String, depth: Int = 0) {
        #expect(depth < 8, "\(path): shape too deep to be an event")
        #expect(
            !(value is String) && !(value is Data) && !(value is [String: Any]),
            "\(path) is a free-form carrier")
        for child in Mirror(reflecting: value).children {
            expectNoFreeFormCarrier(
                in: child.value, path: "\(path).\(child.label ?? "?")", depth: depth + 1)
        }
    }

    /// The mirror walk types the VALUES; this scans the DECLARATIONS, so an
    /// event gaining a `String`/`Data`/dictionary parameter — including on the
    /// protocol methods themselves — fails even before an instance exists.
    @Test func telemetryGuardDeclarationsCarryNoFreeFormTypes() throws {
        let file = Self.packageSources.appendingPathComponent("ImageImportTelemetryGuard.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let code = rawLine.components(separatedBy: "//").first ?? rawLine
            for token in [": String", ": Data", "[String:"] {
                #expect(
                    !code.contains(token),
                    """
                    ImageImportTelemetryGuard.swift:\(index + 1) declares \
                    '\(token)', a free-form carrier — a security-policy change
                    """)
            }
        }
    }

    /// The §7 allowlists and caps are one keystroke from being widened at a call
    /// site that passes a custom config; production must construct BOTH bounded
    /// decoders with NO arguments (binding note on ios-dts.3 — the barcode lane's
    /// config carries the wider five-container roster, the byte cap and the wait
    /// budget). The scan RECURSES so a call site cannot escape into a subfolder.
    @Test func productionConstructsBothDecodersWithNoConfigArgument() throws {
        let files = try Self.allPackageSourceFiles()
        try #require(!files.isEmpty)
        var callSites = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pin in ["makeBoundedImageDecoder", "VisionBarcodeImageDecoder"] {
                for rawLine in text.components(separatedBy: .newlines) {
                    // Comments naming a decoder are not call sites.
                    let code = rawLine.components(separatedBy: "//").first ?? rawLine
                    guard code.contains(pin) else { continue }
                    callSites += 1
                    #expect(
                        code.contains("\(pin)()"),
                        "decoder constructed with arguments: \(code.trimmingCharacters(in: .whitespaces))"
                    )
                }
            }
        }
        try #require(callSites >= 2, "both production decoder call sites must exist")
    }

    /// The importer's `ImageFormat` and storage's `DocumentInsert.ImageFormat`
    /// are two rosters with no compile-time link (the mapping is the consumer's
    /// seam); adding a container to one and not the other must fail HERE, not at
    /// the app's switch in another repo.
    @Test func imageFormatRosterMatchesStorage() {
        let importer = ImageFormat.allCases.map { "\($0)" }.sorted()
        let storage = DocumentInsert.ImageFormat.allCases.map { "\($0)" }.sorted()
        #expect(importer == storage)
    }

    /// Flipping a default is a deliberate, test-breaking change (the
    /// PublicApiSurfaceTests convention): the read ceiling matches the backends'
    /// caps, the decode bound sits at the decoder's own output ceiling, and the
    /// no-op guard is the silent default.
    @Test func documentImportConfigDefaultsAreLocked() {
        let config = DocumentImportConfig()
        #expect(config.maxBytes == 25 * 1024 * 1024)
        // The reader-thread ceiling is a security bound (image-decode-1); the
        // primitive tests build their own banks, so the production cap pins here.
        #expect(SourceReadSlots.defaultCapacity <= 4)
        #expect(Int64(config.maxBytes) == config.pdfConfig.maxBytes)
        #expect(config.maxImageDecodePx == 2048)
        #expect(config.sourceReadTimeout == .seconds(10))
        // The default guard is the no-op; exercising it pins that it stays inert.
        config.imageTelemetryGuard.onImportStarted()
        config.imageTelemetryGuard.onImportSucceeded(
            event: ImageImportSucceededEvent(
                byteCount: 1, format: .png, widthPx: 1, heightPx: 1, durationMillis: 1))
        config.imageTelemetryGuard.onImportFailed(
            event: ImageImportFailedEvent(outcome: .decode, durationMillis: 1))
    }

    static let packageSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PassesDocumentTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/PassesDocument")

    static func allPackageSourceFiles() throws -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: packageSources, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
