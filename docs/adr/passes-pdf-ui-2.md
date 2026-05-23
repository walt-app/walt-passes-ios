# passes-pdf-ui-2: `PDFThumbnailViewModel` (`@Observable`) replaces `rememberPdfThumbnail` Composable

Android's `rememberPdfThumbnail` returns a `PdfThumbnailState` driven by Compose's `produceState`. SwiftUI has no direct `produceState` analogue; the iOS port models the same surface as an `@Observable @MainActor` view model with a `start(...)` / `stop()` lifecycle the hosting view drives from `onAppear` / `onDisappear`. The exposed state arms (`loading` / `rendered` / `failed`) are identical to Android's; the trust shape is preserved.

Android source: `passes-android-main/passes-pdf-ui/src/main/kotlin/is/walt/passes/pdf/ui/PdfThumbnail.kt`.
