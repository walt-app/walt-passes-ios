import Foundation
import PassesPDFCore

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Decode a stored page raster (a Walt-produced PNG, ios-dts.16 render-once)
/// into a drawable `PageImage`. This is the display path's ONLY pixel source:
/// the bytes are first-party output of Walt's own renderer + PNG encoder,
/// persisted at import — never the untrusted source document, which this
/// module can no longer reach (it has no PDF-parser dependency at all).
///
/// The aspect is taken from the decoded image itself; `renderFitted` produced
/// aspect-correct dimensions at import, so no separate page-aspect travels.
func decodeStoredRaster(_ raster: StoredPageRaster) -> PageImage? {
    guard
        let source = CGImageSourceCreateWithData(raster.pngBytes as CFData, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
        cgImage.width > 0, cgImage.height > 0
    else {
        return nil
    }
    let aspect = Float(cgImage.width) / Float(cgImage.height)
    return PageImage(cgImage: cgImage, pageAspect: aspect)
}
#endif

/// Map an arbitrary `Error` to a `ConsumerRenderFailure`. The shape mirrors
/// the Android `consumerRenderFailureFor` dispatch table; on iOS the
/// specific exception classes do not exist as types, so the mapping uses
/// the closest semantic equivalents and otherwise routes to `.other`. A
/// spike on `.other` in production is the signal to add a new mapping.
func consumerRenderFailureFor(_ error: Error) -> ConsumerRenderFailure {
    if error is OutOfMemoryError {
        return .outOfMemory
    }
    if error is DimensionMismatchError {
        return .dimensionMismatch
    }
    if error is SharedMemoryUnavailableError {
        return .sharedMemoryUnavailable
    }
    return .other
}

/// Marker error types kept here so the failure-classification helper has
/// concrete types to dispatch on inside tests. None of these are thrown by
/// production code today; they exist so the mapping table is exhaustive in
/// the same shape as the Android side.
struct OutOfMemoryError: Error {}
struct DimensionMismatchError: Error {}
struct SharedMemoryUnavailableError: Error {}
