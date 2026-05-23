import SwiftUI
import CoreGraphics
import ImageIO
import PassesCore

/// Decodes `bytes` through ImageIO with explicit dimension caps. Prevents a
/// hostile pass archive from forcing a multi-gigabyte image allocation.
///
/// Mirror of Android's `is.walt.passes.ui.BoundedImage`. iOS reads the image
/// header through `CGImageSourceCopyPropertiesAtIndex` before decoding the
/// pixels; if width/height/area exceeds `bounds`, the decode is skipped and
/// `telemetry.onImageDecodeRejected` fires with the categorized reason.
public struct BoundedImage: View {
    let bytes: ImageBytes
    let role: ImageRole
    let contentDescription: String?
    let telemetry: any UiTelemetryGuard
    let bounds: ImageRenderBounds

    @State private var cgImage: CGImage?
    @State private var rejection: ImageDecodeRejection?

    public init(
        bytes: ImageBytes,
        role: ImageRole,
        contentDescription: String?,
        telemetry: any UiTelemetryGuard,
        bounds: ImageRenderBounds = .default
    ) {
        self.bytes = bytes
        self.role = role
        self.contentDescription = contentDescription
        self.telemetry = telemetry
        self.bounds = bounds
    }

    public var body: some View {
        Group {
            if let cgImage = cgImage {
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .accessibilityLabel(Text(contentDescription ?? ""))
            } else {
                Color.clear
            }
        }
        .task(id: bytes.bytes) {
            let rawBytes = bytes.bytes
            let bounds = bounds
            let (decoded, reason) = await Task.detached(priority: .userInitiated) {
                decodeBoundedImage(rawBytes: rawBytes, bounds: bounds)
            }.value
            self.cgImage = decoded
            self.rejection = reason
            if let reason {
                telemetry.onImageDecodeRejected(reason: reason)
            }
        }
    }
}

/// Visible-for-tests pure decoder. Returns the produced `CGImage` or `nil`
/// on failure, plus the rejection reason or `nil` on success. Free function so
/// it has no actor isolation and can be invoked from a detached Task.
internal func decodeBoundedImage(
    rawBytes: Data,
    bounds: ImageRenderBounds
) -> (CGImage?, ImageDecodeRejection?) {
    guard let source = CGImageSourceCreateWithData(rawBytes as CFData, nil) else {
        return (nil, .malformed)
    }
    guard CGImageSourceGetCount(source) > 0 else {
        return (nil, .malformed)
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return (nil, .malformed)
    }
    guard
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
        return (nil, .malformed)
    }
    if width > bounds.maxWidthPx { return (nil, .exceedsWidth) }
    if height > bounds.maxHeightPx { return (nil, .exceedsHeight) }
    if Int64(width) * Int64(height) > bounds.maxAreaPx { return (nil, .exceedsArea) }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return (nil, .malformed)
    }
    return (cgImage, nil)
}
