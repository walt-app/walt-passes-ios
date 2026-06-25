import Foundation
import PassesPDF
import PassesPDFCore

/// Shared decode + cleanup helpers for `DocumentView` and
/// `FullScreenDocumentView`. Both surfaces rasterise pages through the same
/// `PDFRendererBinder`; extracting the primitives here keeps a fix to one
/// site from missing the other.
///
/// Mirror of Android's `PageRendering` internal helpers. iOS does not own a
/// `SharedMemory` handle on the consumer side — `PDFRendererBinder.render`
/// returns plain `Data` — so the close-on-discard semantics collapse to a
/// no-op. The `renderOrDiscard` wrapper is preserved for symmetry with the
/// Android source so a future port adding a handle-owning shape only needs
/// to fill in the cleanup branch.
struct DecodedPage {
    let pixels: Data
    let widthPx: Int
    let heightPx: Int
    let pageAspect: Float
}

/// Reconstructs the rendered page from a `RenderResult.ok(...)`. Returns
/// `nil` when the result cannot be turned into a usable page; telemetry is
/// notified with the failure mode. On iOS the pixel `Data` is always
/// well-formed when the renderer returns `.ok`, so this currently routes
/// every renderer-success to a `DecodedPage`. The mapping shape is
/// preserved so future failure modes (e.g. a `Bitmap`-style copy that can
/// throw) can be added without changing call sites.
func decodePage(
    _ ok: RenderOk,
    telemetry: DocumentTelemetryGuard
) -> DecodedPage? {
    DecodedPage(
        pixels: ok.pixels,
        widthPx: ok.widthPx,
        heightPx: ok.heightPx,
        pageAspect: ok.pageAspect
    )
}

/// Lightweight projection of the `.ok` arm so helpers can pass it without
/// re-matching the outer enum at every call site.
struct RenderOk {
    let pixels: Data
    let widthPx: Int
    let heightPx: Int
    let pageAspect: Float
}

func renderOkFrom(_ result: RenderResult) -> RenderOk? {
    if case .ok(let pixels, let widthPx, let heightPx, let pageAspect) = result {
        return RenderOk(pixels: pixels, widthPx: widthPx, heightPx: heightPx, pageAspect: pageAspect)
    }
    return nil
}

/// Runs `binder.render` and returns its result only when `isStillWanted()`
/// confirms the caller still wants it. When the result is stale the helper
/// drops it on the floor; on Android the same call site also closes a
/// `SharedMemory` handle, which has no analogue on iOS. Mirrors the contract
/// so a future iOS handle-owning shape (e.g. an `IOSurface` or named-memory
/// mapping) can add cleanup in exactly one place.
func renderOrDiscard(
    renderer: PDFRendererBinder,
    pdf: Data,
    target: ThumbnailRenderTarget,
    sourceRect: RenderSourceRect,
    isStillWanted: @Sendable () -> Bool
) async -> RenderResult? {
    // Swift Task cancellation is cooperative; the binder either runs to
    // completion or it itself observes cancellation. Either way the caller
    // gets a result it can either accept or discard via `isStillWanted`.
    let result = await renderer.render(
        pdf: pdf,
        page: target.page,
        widthPx: target.widthPx,
        heightPx: target.heightPx,
        sourceRect: sourceRect
    )
    return isStillWanted() ? result : nil
}

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
