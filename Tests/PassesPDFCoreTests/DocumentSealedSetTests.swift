import Foundation
import Testing

@testable import PassesPDFCore

/// The sealed `Document` supertype (mirror of Android wpass-gyn + the wpass-bsf image
/// arm, ios-dts.2): shared fields are reachable through `any Document`, each arm keeps
/// its kind-specific field on the arm (never the supertype), and the per-arm id types
/// cannot be substituted for one another. Swift has no sealed protocols, so the closed
/// arm set is pinned here — a new conformance must reconcile this test deliberately.
@Suite("Document sealed set")
struct DocumentSealedSetTests {

    private let pdf = PDFDocument(
        id: PDFDocumentId("p1"), displayLabel: "Boarding", byteCount: 100,
        pageCount: 3, importedAtEpochMs: 42)

    private let image = ImageDocument(
        id: ImageDocumentId("i1"), displayLabel: "Receipt", byteCount: 200,
        widthPx: 640, heightPx: 480, importedAtEpochMs: 43)

    private let composite = BarcodedImageDocument(
        id: BarcodedImageDocumentId("b1"), displayLabel: "Loyalty", byteCount: 300,
        widthPx: 320, heightPx: 240, barcodePayload: "MEMBER-1", barcodeFormat: .qr,
        importedAtEpochMs: 44)

    @Test func sharedFieldsAreReachableThroughTheSupertype() {
        let documents: [any Document] = [pdf, image, composite]
        #expect(documents.map(\.displayLabel) == ["Boarding", "Receipt", "Loyalty"])
        #expect(documents.map(\.byteCount) == [100, 200, 300])
        #expect(documents.map(\.importedAtEpochMs) == [42, 43, 44])
        #expect(documents.allSatisfy { $0.provenance == .userProvided })
    }

    @Test func perArmIdsSurfaceThroughTheDocumentIdSupertype() {
        let ids: [any DocumentId] = [pdf.id, image.id, composite.id]
        #expect(ids.map(\.value) == ["p1", "i1", "b1"])
        // And through `any Document` itself (Android's `val id: DocumentId`).
        let documents: [any Document] = [pdf, image, composite]
        #expect(documents.map(\.documentId.value) == ["p1", "i1", "b1"])
    }

    /// The arm roster travels with `documentArms` in the source file; this checks
    /// the roster's CONTENT (a conformance added without touching `documentArms`
    /// is caught in review by the doc contract, not by this test — Swift has no
    /// sealed protocols to make that mechanical).
    @Test func theArmSetIsExactlyPdfImageAndBarcodedImage() {
        let arms = documentArms.map(ObjectIdentifier.init)
        #expect(
            arms == [
                ObjectIdentifier(PDFDocument.self), ObjectIdentifier(ImageDocument.self),
                ObjectIdentifier(BarcodedImageDocument.self),
            ])
    }

    @Test func compositeCarriesTheBarcodePairAndNoExtractionOutcome() {
        // The model carries only what was FOUND (payload + symbology), never why
        // nothing was: BarcodeExtractionOutcome rides the persist seam, not the
        // stored artifact.
        #expect(composite.barcodePayload == "MEMBER-1")
        #expect(composite.barcodeFormat == .qr)
        let mirror = Mirror(reflecting: composite)
        #expect(!mirror.children.contains { $0.label == "barcodeExtraction" })
        #expect(!mirror.children.contains { $0.label == "format" })
    }

    @Test func imageDocumentCarriesDimensionsAndNoContainerFormat() {
        // The kind-specific fields live on the arm: dimensions for images, page
        // count for PDFs. No `format` property exists on the model (persistence
        // detail; display renders a Walt-produced raster, never the codec stream).
        #expect(image.widthPx == 640)
        #expect(image.heightPx == 480)
        let mirror = Mirror(reflecting: image)
        #expect(!mirror.children.contains { $0.label == "format" })
    }
}
