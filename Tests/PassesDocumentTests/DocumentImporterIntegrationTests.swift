import CoreGraphics
import Foundation
import ImageIO
import PassesCore
import Testing
import UniformTypeIdentifiers

@testable import PassesDocument

/// End-to-end through the REAL importer — real bounded image decode, real Vision
/// barcode extraction, real PDF sniff — the iOS analogue of Android's
/// `CompositeImportInstrumentedTest`, runnable in the normal suite because the
/// decoders are in-process (§7). Fixtures are generated with the kernel's own
/// `BarcodeEncoder`.
@Suite("Document importer integration")
struct DocumentImporterIntegrationTests {

    @Test func qrBearingPngImportsAsOneCompositeArtifact() async throws {
        let png = try Self.qrPng(payload: "WALT-COMPOSITE-1")
        nonisolated(unsafe) var persisted: [DocumentPersist] = []
        let result = try await makeDocumentImporter().import(
            source: .data(png), displayLabel: "Loyalty",
            confirmBarcode: { payload, _ in payload == "WALT-COMPOSITE-1" },
            persist: { persisted.append($0) })

        guard case .importedBarcodedImage(let doc) = result else {
            Issue.record("expected composite, got \(result)")
            return
        }
        // The SAME single row carries the image bytes AND the barcode.
        #expect(doc.barcodePayload == "WALT-COMPOSITE-1")
        #expect(doc.barcodeFormat == .qr)
        guard case .barcodedImage(_, let bytes, let thumb, let format, _, _, _, _) = persisted.first
        else {
            Issue.record("expected barcodedImage persist, got \(persisted)")
            return
        }
        #expect(bytes == png, "original bytes persist verbatim")
        #expect(!thumb.isEmpty, "thumbnail is a Walt-produced PNG")
        #expect(format == .png)
    }

    @Test func declinedConfirmationImportsAsAPlainImage() async throws {
        let png = try Self.qrPng(payload: "DECLINE-ME")
        nonisolated(unsafe) var persisted: [DocumentPersist] = []
        let result = try await makeDocumentImporter().import(
            source: .data(png), displayLabel: "Photo",
            confirmBarcode: { _, _ in false },
            persist: { persisted.append($0) })

        guard case .importedImage = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        guard case .image(_, _, _, _, _, _, let extraction) = persisted.first else {
            Issue.record("expected image persist, got \(persisted)")
            return
        }
        #expect(extraction == .declined)
    }

    @Test func barcodeLessPhotoImportsAsAPlainImage() async throws {
        let png = try Self.plainPng(width: 64, height: 48)
        nonisolated(unsafe) var persisted: [DocumentPersist] = []
        let result = try await makeDocumentImporter().import(
            source: .data(png), displayLabel: "Photo",
            confirmBarcode: { _, _ in true },
            persist: { persisted.append($0) })

        guard case .importedImage(let doc) = result else {
            Issue.record("expected plain image, got \(result)")
            return
        }
        #expect(doc.widthPx == 64)
        #expect(doc.heightPx == 48)
        guard case .image(_, _, _, _, _, _, let extraction) = persisted.first else {
            Issue.record("expected image persist, got \(persisted)")
            return
        }
        #expect(extraction == .noCodeFound)
    }

    // MARK: - Fixtures

    struct FixtureUnsupported: Error {}

    /// A real QR symbol from the kernel's own encoder, drawn onto a white
    /// quiet-zone canvas and PNG-encoded.
    static func qrPng(payload: String) throws -> Data {
        guard case .success(let symbol) = BarcodeEncoder.encode(payload: payload, format: .qr),
            case .image(let qr) = symbol
        else { throw FixtureUnsupported() }
        let scale = 8
        let quiet = 32
        let width = qr.width * scale + quiet * 2
        let height = qr.height * scale + quiet * 2
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw FixtureUnsupported() }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(
            qr,
            in: CGRect(
                x: quiet, y: quiet, width: qr.width * scale, height: qr.height * scale))
        guard let image = context.makeImage() else { throw FixtureUnsupported() }
        return try encodePngFixture(image)
    }

    static func plainPng(width: Int, height: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw FixtureUnsupported() }
        context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureUnsupported() }
        return try encodePngFixture(image)
    }

    private static func encodePngFixture(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureUnsupported() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureUnsupported() }
        return out as Data
    }
}
