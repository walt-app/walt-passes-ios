import Testing
import SwiftUI
import PassesPDF
import PassesPDFCore
import PassesUICore

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

    private static let pdfData = Data()
    private static let renderer: PDFRendererBinder = StaticRejectingRenderer()

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
            pdfData: Self.pdfData,
            renderer: Self.renderer
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func documentViewConstructsWithFullScreenCallback() {
        let v = DocumentView(
            doc: Self.doc,
            pdfData: Self.pdfData,
            renderer: Self.renderer,
            onOpenFullScreen: {}
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func fullScreenDocumentViewConstructs() {
        let v = FullScreenDocumentView(
            doc: Self.doc,
            pdfData: Self.pdfData,
            renderer: Self.renderer,
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

private struct StaticRejectingRenderer: PDFRendererBinder {
    func probe(pdf: Data) async -> ProbeResult {
        .rejected(kind: .rendererFailed)
    }
    func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult {
        .rejected(kind: .rendererFailed)
    }
}
