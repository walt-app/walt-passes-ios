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

    @Test func sharedFieldsAreReachableThroughTheSupertype() {
        let documents: [any Document] = [pdf, image]
        #expect(documents.map(\.displayLabel) == ["Boarding", "Receipt"])
        #expect(documents.map(\.byteCount) == [100, 200])
        #expect(documents.map(\.importedAtEpochMs) == [42, 43])
        #expect(documents.allSatisfy { $0.provenance == .userProvided })
    }

    @Test func perArmIdsSurfaceThroughTheDocumentIdSupertype() {
        let ids: [any DocumentId] = [pdf.id, image.id]
        #expect(ids.map(\.value) == ["p1", "i1"])
    }

    /// The arm roster travels with `documentArms` in the source file; this checks
    /// the roster's CONTENT (a conformance added without touching `documentArms`
    /// is caught in review by the doc contract, not by this test — Swift has no
    /// sealed protocols to make that mechanical).
    @Test func theArmSetIsExactlyPdfAndImage() {
        let arms = documentArms.map(ObjectIdentifier.init)
        #expect(arms == [ObjectIdentifier(PDFDocument.self), ObjectIdentifier(ImageDocument.self)])
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
