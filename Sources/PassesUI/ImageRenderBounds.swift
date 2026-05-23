import Foundation

/// Hard upper bounds for decoded image dimensions, enforced by `BoundedImage`.
/// Prevents a malformed archive from forcing a multi-gigabyte image allocation.
/// Mirror of Android's `is.walt.passes.ui.ImageRenderBounds`.
public struct ImageRenderBounds: Sendable, Equatable {
    public let maxWidthPx: Int
    public let maxHeightPx: Int
    public let maxAreaPx: Int64

    public init(maxWidthPx: Int, maxHeightPx: Int, maxAreaPx: Int64) {
        precondition(maxWidthPx > 0, "maxWidthPx must be positive, was \(maxWidthPx)")
        precondition(maxHeightPx > 0, "maxHeightPx must be positive, was \(maxHeightPx)")
        precondition(maxAreaPx > 0, "maxAreaPx must be positive, was \(maxAreaPx)")
        self.maxWidthPx = maxWidthPx
        self.maxHeightPx = maxHeightPx
        self.maxAreaPx = maxAreaPx
    }

    /// 1920 x 1920 with a 4-megapixel area cap. The largest documented PKPASS
    /// asset is well under both per-axis caps; the default bounds a hostile
    /// archive, not legitimate content.
    public static let `default` = ImageRenderBounds(
        maxWidthPx: 1920,
        maxHeightPx: 1920,
        maxAreaPx: 4_000_000
    )
}
