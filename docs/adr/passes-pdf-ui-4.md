# passes-pdf-ui-4: Sub-rect zoom render path deferred on iOS full-screen surface

> **Superseded in part by `pdf-render-once-1` (ios-dts.16, 2026-08-18):** the deferred
> sub-rect render is now permanently foreclosed — the display layer no longer holds a
> renderer at all; full-screen zoom is a `scaleEffect` over the stored 4 MP raster, and
> `clampToMaxPixels` / `FullScreenDimensionClampTests` were removed with the live render
> requests. The gesture-surface record below still applies.

Android's `FullScreenDocumentView` fires a `renderer.render(SubRect)` call on pinch settle and swaps the displayed bitmap when the result returns, achieving sharp-at-zoom rendering within the 4 MP per-bitmap cap. The iOS port lands the gesture surface (pinch / pan / double-tap) and the dimension-clamp math (`clampToMaxPixels`) but does NOT yet wire the settled-zoom sub-rect render swap. The base bitmap is the only image displayed; pinch-zoom scales it bilinearly via SwiftUI `scaleEffect`.

Trust posture is unaffected: the sub-rect path is a sharpness optimisation, not a trust control. The `RenderSourceRect.subRect` arm and the renderer's per-rect validation already exist in `PassesPDF`; wiring it through `ZoomableImage` is a follow-up that does not change any public surface.

Tracked as follow-up; revisit when zoom sharpness becomes a user-visible concern.

Android source: `passes-android-main/passes-pdf-ui/src/main/kotlin/is/walt/passes/pdf/ui/internal/ZoomableImage.kt`, `FullScreenDocumentView.kt` (`FullScreenPage` sub-rect `LaunchedEffect`).
