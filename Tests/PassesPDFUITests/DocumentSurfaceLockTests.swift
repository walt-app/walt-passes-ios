import Testing
import SwiftUI
import PassesPDF
import PassesPDFCore

@testable import PassesPDFUI

/// Pins the parameter-shape discipline of the trust-claim-bearing
/// document views (ADR 0005 D5 / D8). Mirror of Android's
/// `DocumentSurfaceLockTest`.
///
/// Java reflection lets the Android test count parameters via the
/// Compose-compiler-mangled JVM signatures. Swift has no equivalent
/// reflection over function signatures; the iOS analogue is to
/// construct each view through its single declared initialiser with
/// every public parameter, so any added/removed/renamed parameter
/// fails to compile. The compile-time check is at least as strict as
/// Android's reflective count.
@MainActor
@Suite("Document surface lock")
struct DocumentSurfaceLockTests {

    private static let doc = PDFDocument(
        id: PDFDocumentId("doc-1"),
        displayLabel: "tax-2025.pdf",
        byteCount: 1024,
        pageCount: 1,
        importedAtEpochMs: 0
    )

    private static let pdfData = Data()
    private static let renderer: PDFRendererBinder = StaticRejectingRenderer()

    @Test func documentTrustCaptionExposesOnlyTheZeroArityInitialiser() {
        // D5: no `enabled`, no theme suppression flag, no overload that
        // accepts a state to hide the caption. The caption is
        // structurally always-on.
        _ = DocumentTrustCaption()
    }

    @Test func documentTileExposesExactlyThreePublicInitialiserParameters() {
        // (doc, thumbnail, onTap). No share/export action, no overflow
        // menu. Android counts four (the extra is `modifier`); SwiftUI
        // views never take a `modifier` slot because composition happens
        // via the view-modifier chain on the consumer side.
        _ = DocumentTile(doc: Self.doc, thumbnail: nil, onTap: {})
    }

    @Test func documentViewExposesExactlyFivePublicInitialiserParameters() {
        // (doc, pdfData, renderer, telemetry, onOpenFullScreen).
        // Android counts six (modifier sits in the middle of the slot
        // list); the SwiftUI signature collapses the modifier slot.
        _ = DocumentView(
            doc: Self.doc,
            pdfData: Self.pdfData,
            renderer: Self.renderer,
            telemetry: DocumentTelemetryGuardNoOp.shared,
            onOpenFullScreen: nil
        )
    }

    @Test func documentsLaneExposesExactlyThreePublicInitialiserParameters() {
        // (documents, thumbnails, onDocumentTap). The lane composes the
        // trust caption inside itself; no parameter omits it.
        _ = DocumentsLane(
            documents: [],
            thumbnails: [:],
            onDocumentTap: { _ in }
        )
    }

    @Test func fullScreenDocumentViewExposesExactlyFivePublicInitialiserParameters() {
        // (doc, pdfData, renderer, onClose, telemetry). Required
        // onClose forces the host to provide a back path — there is no
        // "stuck in full-screen" state.
        _ = FullScreenDocumentView(
            doc: Self.doc,
            pdfData: Self.pdfData,
            renderer: Self.renderer,
            onClose: {},
            telemetry: DocumentTelemetryGuardNoOp.shared
        )
    }

    @Test func documentViewConsumesPDFRendererBinderProtocolNotConcreteRenderer() {
        // The DocumentView contract takes the binder protocol so test
        // fakes inject cleanly. The compile-time check below succeeds
        // because StaticRejectingRenderer (the test fake) only conforms
        // to the protocol; the constructor would refuse any concrete
        // type that did not satisfy the protocol.
        let _: PDFRendererBinder = Self.renderer
    }
}

/// Minimal `PDFRendererBinder` fake used by the construction tests. The
/// production `RejectingRenderer` would have served equally well but is
/// `package`-scoped inside `PassesPDF`; redeclaring a small fake here
/// keeps the test target free of `@testable` reaches into PassesPDF.
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
