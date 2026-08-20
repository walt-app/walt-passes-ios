import Foundation
import PassesImage
import PassesPDFCore
import SwiftUI

/// The image-arm sibling of `decodeStoredRaster` (mirror of Android's
/// `internal/ImageRendering.kt`). Android reconstructs ARGB_8888 pixels out of
/// `SharedMemory` here and can fail doing it; the iOS bounded decoder returns a
/// materialized `CGImage`, so there is no reconstruction step and no
/// consumer-render failure path — the fold is total. Kept as its own seam so
/// the state mapping is testable without a view and the two arms' fold logic
/// lives where the Android file does.
struct DecodedDocumentImage {
    let image: Image
    let sourceAspect: Float
}

enum DocumentImageFold {
    case rendered(DecodedDocumentImage)
    case failed(ImageDecodeRejectedKind)
}

/// Folds the bounded decode's outcome onto the display state. `telemetry` is
/// accepted for shape parity with the PDF fold; with no reconstruction step
/// nothing here can fail after a successful decode, so it is never notified.
func foldDecodedImage(
    _ result: ImageDecodeResult, telemetry: DocumentTelemetryGuard
) -> DocumentImageFold {
    switch result {
    case .rejected(let kind):
        return .failed(kind)
    case .ok(let raster):
        return .rendered(
            DecodedDocumentImage(
                image: Image(decorative: raster.image, scale: 1),
                sourceAspect: raster.sourceAspect))
    }
}
