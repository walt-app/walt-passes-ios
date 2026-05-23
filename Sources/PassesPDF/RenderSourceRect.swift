import Foundation

/// Selects what portion of a PDF page is rasterised. Mirrors Android's
/// `RenderSourceRect` sealed interface. Sealed so the importer, renderer, and
/// any future tiled-rendering path all fold over the same closed set;
/// growing the surface is a deliberate change everywhere.
public enum RenderSourceRect: Sendable, Equatable {
    /// Rasterise the entire page. The pre-sub-rect behaviour.
    case fullPage

    /// Sub-rectangle in normalised page coordinates: `(0, 0)` is top-left,
    /// `(1, 1)` is bottom-right. Invalid rects (outside the unit square,
    /// zero area, reversed, non-finite) are rejected by the renderer with
    /// `.rendererFailed`.
    case subRect(left: Float, top: Float, right: Float, bottom: Float)
}

/// Strict ordering rules out zero-area rects (would produce a degenerate
/// transform); the unit-square bound keeps consumer failures visible
/// instead of silently blank. Mirrors Android's `isSourceRectValid`.
public func isSourceRectValid(_ sourceRect: RenderSourceRect) -> Bool {
    switch sourceRect {
    case .fullPage:
        return true
    case let .subRect(left, top, right, bottom):
        let finite = left.isFinite && top.isFinite && right.isFinite && bottom.isFinite
        return finite
            && (0.0...1.0).contains(left)
            && (0.0...1.0).contains(top)
            && (0.0...1.0).contains(right)
            && (0.0...1.0).contains(bottom)
            && left < right
            && top < bottom
    }
}
