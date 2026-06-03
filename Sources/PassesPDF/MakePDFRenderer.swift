import Foundation
import PassesPDFCore

/// Convenience factory for a production ``PDFRendererBinder``, the renderer that
/// `PassesPDFUI`'s `DocumentView` / `FullScreenDocumentView` require to draw a
/// stored PDF. The concrete `PDFKitRenderer` is package-private (test seams stay
/// off the public surface); this is the public seam a host uses to render a
/// document it has already imported.
///
/// Sibling of ``makePDFImporter(config:)``. On platforms without PDFKit (non-Apple
/// hosts) it returns a renderer that rejects every probe/render with
/// ``PassesPDFCore/DocumentRejectedKind/rendererFailed`` so the UI degrades to the
/// failure path rather than failing to compile.
public func makePDFRenderer(
    maxPages: Int = PDFImportConfig.defaultMaxPages
) -> any PDFRendererBinder {
    #if canImport(PDFKit)
    return PDFKitRenderer(maxPages: maxPages)
    #else
    return RejectingRenderer(kind: .rendererFailed)
    #endif
}
