# passes-pdf-ui-3: `SwiftUI.TabView(.page)` replaces Compose `HorizontalPager`

Android's `DocumentView` and `FullScreenDocumentView` use Compose's `HorizontalPager` with `rememberPagerState`. SwiftUI's equivalent is `TabView` styled with `.page(indexDisplayMode: .never)`. The page-cache discipline (LRU bounded at `defaultPageWindow = 5`) is preserved through `RenderedPageCache`. The dot indicator is suppressed so the visual treatment matches Android's "no indicator" pager configuration.

`FullScreenDocumentView` takes a defaulted `initialPage` (mirror of passes-android #277), clamped into the page range and seeded into the pager's selection, so a host that pages inline itself can open full screen on the page being viewed. `DocumentView.onOpenFullScreen` is unchanged and the image arms ignore it.

Android source: `passes-android-main/passes-pdf-ui/src/main/kotlin/is/walt/passes/pdf/ui/DocumentView.kt`, `FullScreenDocumentView.kt`.
