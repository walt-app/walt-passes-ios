import Foundation
import PassesPDFCore

/// A ``PDFRendererBinder`` that returns the same
/// ``PassesPDFCore/DocumentRejectedKind`` for every probe and every render.
/// Used by callers to surface a connect-time failure through the same
/// probe/render shape as a real binder; the importer's existing rejection
/// routing then folds it onto ``PassesPDFCore/DocumentRejectedKind`` without
/// a separate "session connect failed" code path.
///
/// Mirrors Android's `RejectingBinder`. Lifted to its own type because the
/// shape is also useful for unit-test fakes.
package struct RejectingRenderer: PDFRendererBinder {
    private let kind: DocumentRejectedKind

    package init(kind: DocumentRejectedKind) {
        self.kind = kind
    }

    package func probe(pdf: Data) async -> ProbeResult {
        .rejected(kind: kind)
    }

    package func render(
        pdf: Data,
        page: Int,
        widthPx: Int,
        heightPx: Int,
        sourceRect: RenderSourceRect
    ) async -> RenderResult {
        .rejected(kind: kind)
    }
}
