import Foundation

/// A Walt-produced page raster: the PNG encode of one document page, rendered
/// once at import time (ios-dts.16). `widthPx`/`heightPx` are the raster's own
/// pixel dimensions — aspect-correct by construction (`renderFitted`), so the
/// display aspect is `widthPx / heightPx` and no separate page-aspect field is
/// carried.
///
/// Trust posture: the bytes are first-party output of Walt's own renderer +
/// PNG encoder. They are NOT the untrusted source document. Display surfaces
/// decode these and only these; the original bytes never reach a PDF parser
/// after import (the render-once contract this type exists to carry).
public struct StoredPageRaster: Sendable, Equatable {
    public let pngBytes: Data
    public let widthPx: Int
    public let heightPx: Int

    public init(pngBytes: Data, widthPx: Int, heightPx: Int) {
        self.pngBytes = pngBytes
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// Per-document supplier of stored page rasters — the ONLY page-pixel seam the
/// display surfaces (`DocumentView` / `FullScreenDocumentView`) accept since
/// ios-dts.16. The deliberate absence of any "render from PDF bytes" arm is
/// the trust claim: a consumer holding only a `DocumentPageSource` cannot
/// cause untrusted document bytes to be re-parsed.
///
/// `nil` means "no raster for this page" (a legacy pre-raster document, or a
/// lost blob). The self-heal wrapper in `PassesPDF`
/// (`RerenderOnMissPageSource`) is the one sanctioned place a miss may fall
/// back to a single bounded re-render of the originals.
public protocol DocumentPageSource: Sendable {
    func pageRaster(page: Int) async -> StoredPageRaster?
}
