import Foundation
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
    /// DocumentTelemetryGuard discipline). Checked structurally via Mirror.
    @Test func telemetryEventShapesCarryNoStringsOrBytes() {
        let events: [Any] = [
            ImageImportSucceededEvent(
                byteCount: 1, format: .png, widthPx: 2, heightPx: 3, durationMillis: 4),
            ImageImportFailedEvent(outcome: .decode, durationMillis: 1),
        ]
        for event in events {
            for child in Mirror(reflecting: event).children {
                let value = child.value
                #expect(
                    !(value is String) && !(value is Data) && !(value is [String: Any]),
                    "\(type(of: event)).\(child.label ?? "?") is a free-form carrier"
                )
            }
        }
    }

    /// The §7 allowlist is one keystroke from being widened at a call site that
    /// passes a custom config; production must construct the image decoder with
    /// NO arguments (binding note on ios-dts.3).
    @Test func productionConstructsTheImageDecoderWithNoConfigArgument() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PassesDocumentTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/PassesDocument")
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty)
        var callSites = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines)
            where line.contains("makeBoundedImageDecoder") {
                callSites += 1
                #expect(
                    line.contains("makeBoundedImageDecoder()"),
                    "decoder constructed with arguments: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        try #require(callSites > 0, "the production decoder call site must exist")
    }
}
