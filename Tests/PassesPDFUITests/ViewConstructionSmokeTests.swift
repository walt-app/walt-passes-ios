import Foundation
import PassesImage
import PassesPDFCore
import PassesUICore
import SwiftUI
import Testing

@testable import PassesPDFUI

/// Compile-time + cheap-runtime smoke tests for every public view.
/// Equivalent in role to Android's Robolectric `composeRule.setContent`
/// renders: the assertion that a view's `body` resolves to a non-`Never`
/// type means the view's signature compiles and its body type-checks.
/// Catches accidental signature changes at build time.
@MainActor
@Suite("View construction smoke")
struct ViewConstructionSmokeTests {

    private static let doc = PDFDocument(
        id: PDFDocumentId("doc-1"),
        displayLabel: "tax-2025.pdf",
        byteCount: 1024,
        pageCount: 1,
        importedAtEpochMs: 0
    )

    private static let pages: any DocumentPageSource = StaticEmptyPageSource()

    private static let imageDoc = ImageDocument(
        id: ImageDocumentId("img-1"), displayLabel: "Receipt", byteCount: 100,
        widthPx: 640, heightPx: 480, importedAtEpochMs: 0)

    private static let compositeDoc = BarcodedImageDocument(
        id: BarcodedImageDocumentId("bimg-1"), displayLabel: "Loyalty", byteCount: 100,
        widthPx: 640, heightPx: 480, barcodePayload: "M-1", barcodeFormat: .qr,
        importedAtEpochMs: 0)

    @Test func documentTrustCaptionConstructs() {
        let v = DocumentTrustCaption()
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentTileConstructs() {
        let v = DocumentTile(doc: Self.doc, thumbnail: nil, onTap: {})
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentsLaneConstructsWithEmptyDocuments() {
        let v = DocumentsLane(
            documents: [],
            thumbnails: [:],
            onDocumentTap: { _ in }
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentsLaneConstructsWithDocuments() {
        let v = DocumentsLane(
            documents: [Self.doc],
            thumbnails: [:],
            onDocumentTap: { _ in }
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsWithoutFullScreenCallback() {
        let v = DocumentView(
            doc: Self.doc,
            pages: Self.pages
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsWithFaceTint() {
        // The tinted branch has no consumer yet, so this is its only body
        // evaluation until the app wires ios-pjs.8. Also the one construction
        // of the per-page -> container background hoist.
        let v = DocumentView(
            doc: Self.doc,
            pages: Self.pages,
            faceTint: ArgbColor(argb: 0xFFCE_E6FF)
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsWithFullScreenCallback() {
        let v = DocumentView(
            doc: Self.doc,
            pages: Self.pages,
            onOpenFullScreen: {}
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsTheImageArm() {
        let v = DocumentView(
            doc: Self.imageDoc,
            imageSource: .data(Data([0x89])),
            imageDecoder: RejectingDecoder(),
            onOpenFullScreen: {}
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsTheCompositeArmOverTheSameImagePair() {
        // wpass-8lu: same imageSource/imageDecoder pair, no composite-specific
        // parameter — the barcode half is consumer-composed with PassesUI.
        let v = DocumentView(
            doc: Self.compositeDoc,
            imageSource: .data(Data([0x89])),
            imageDecoder: RejectingDecoder(),
            faceTint: ArgbColor(argb: 0xFFCE_E6FF)
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func fullScreenDocumentViewConstructs() {
        let v = FullScreenDocumentView(
            doc: Self.doc,
            pages: Self.pages,
            onClose: {}
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentTileWrapsDisplayLabelInBidiIsolates() {
        // The user-controlled `displayLabel` is wrapped in U+2068 /
        // U+2069 by `PassesUICore::isolated`. The wrap is the structural
        // defense against an attacker-controlled filename reordering
        // surrounding chrome glyphs; the view applies the wrap before
        // handing the string to the SwiftUI text node.
        let isolated = isolated(Self.doc.displayLabel)
        #expect(isolated == "\u{2068}tax-2025.pdf\u{2069}")
    }
}

/// Minimal decoder fake for the image-arm constructions: every decode rejects.
private struct RejectingDecoder: BoundedImageDecoder {
    func decode(
        source: ImageDecodeSource, maxWidthPx: Int, maxHeightPx: Int
    ) async -> ImageDecodeResult {
        .rejected(.decodeFailed)
    }
}

private struct StaticEmptyPageSource: DocumentPageSource {
    func pageRaster(page: Int) async -> StoredPageRaster? { nil }
}
