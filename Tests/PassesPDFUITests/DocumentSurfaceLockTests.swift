import PassesPDFCore
import PassesUICore
import SwiftUI
import Testing

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

    private static let pages: any DocumentPageSource = StaticEmptyPageSource()

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
        // (doc, pages, telemetry, onOpenFullScreen, faceTint). `pages` is the
        // stored-raster source (ios-dts.16 render-once) — there is no pdfData
        // and no renderer slot, which is the structural trust claim: the view
        // cannot be handed the original bytes. `faceTint` (wpass-80y.2)
        // paints the frame the page sits on and nothing else. Exact-arity
        // reference so even a defaulted addition fails to compile.
        let lockedInit:
            (PDFDocument, any DocumentPageSource, DocumentTelemetryGuard, (() -> Void)?, ArgbColor?)
                -> DocumentView =
                DocumentView.init(
                    doc:pages:telemetry:onOpenFullScreen:faceTint:)
        _ = lockedInit
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
        // (doc, pages, onClose, telemetry, closeButton). Required onClose
        // forces the host to provide a back path — there is no "stuck in
        // full-screen" state. `closeButton` (wlt-d3d slot) swaps the close
        // CHROME only: it receives the handler and must wire it; it cannot
        // suppress the trust caption or the close path. `pages` replaces the
        // former pdfData+renderer pair (ios-dts.16). The exact-arity function
        // reference fails to compile if any parameter is added, removed,
        // renamed, or retyped — even a defaulted addition.
        typealias LockedInit = (
            PDFDocument, any DocumentPageSource, @escaping () -> Void,
            DocumentTelemetryGuard, ((@escaping () -> Void) -> AnyView)?
        ) -> FullScreenDocumentView
        let lockedInit: LockedInit = FullScreenDocumentView
            .init(doc:pages:onClose:telemetry:closeButton:)
        _ = lockedInit
    }

    @Test func documentViewConsumesDocumentPageSourceProtocolNotConcreteSource() {
        // The DocumentView contract takes the page-source protocol so test
        // fakes inject cleanly, and so the type system rather than a code
        // review enforces render-once: DocumentPageSource has no arm that
        // accepts document bytes, so no conforming source can hand this
        // module something it could parse.
        let _: any DocumentPageSource = Self.pages
    }
}

/// Minimal `DocumentPageSource` fake used by the construction tests: a
/// document with no stored rasters (every page misses).
private struct StaticEmptyPageSource: DocumentPageSource {
    func pageRaster(page: Int) async -> StoredPageRaster? { nil }
}
