# passes-pdf-ui-5: `Data`-backed pixel buffers replace Android `SharedMemory` / `ParcelFileDescriptor`

> **Superseded in part by `pdf-render-once-1` (ios-dts.16, 2026-08-18):** `renderOrDiscard`,
> `DecodedPage`, and the `pdfData`-by-value paragraph describe the removed live-render
> display path — pages now arrive as stored first-party rasters through
> `DocumentPageSource`, decoded in `PageRendering.swift`'s `decodeStoredRaster`. The
> `consumerRenderFailureFor` dispatch table and its marker types survive unchanged.

Android consumes pages via an IPC binder returning a `SharedMemory` handle; the consumer maps the buffer, copies pixels into a `Bitmap`, then closes the shared region. The iOS port has no isolated-process renderer (`PDFRendererBinder` is in-process PDFKit per `PassesPDF`), and the renderer returns a plain `Data` value. The `renderOrDiscard` helper and the `DecodedPage` shape are preserved in `Sources/PassesPDFUI/Internal/PageRendering.swift` so future iOS handle-owning shapes (e.g. `IOSurface`) can add cleanup in exactly one place. The `consumerRenderFailureFor` dispatch table maps marker error types (`OutOfMemoryError`, `DimensionMismatchError`, `SharedMemoryUnavailableError`) so the failure-classification contract stays exhaustively pinned by tests.

`pdfData` is passed by value (`Data`) instead of a `ParcelFileDescriptor`; lifetime is straightforward Swift value semantics.

Android source: `passes-android-main/passes-pdf-ui/src/main/kotlin/is/walt/passes/pdf/ui/internal/PageRendering.kt`.
