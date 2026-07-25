# passes-pdf-ui-6: PDF pager support audit — no kernel change needed (ipass-65p.2)

The Walt consumer redesign (consumer epic ios-te9; Android analogue wlt-mx2d.8) replaces the document detail hero with a horizontal pager showing a next/previous-page peek. Android needed kernel changes for this (walt-passes-android wpass-tjc.3 / PR #186: configurable cache capacity + adjacent-page prefetch, because evicting a still-painted `Bitmap` crashes). The iOS kernel was audited against the same three needs and already satisfies all of them:

1. **Cache capacity is consumer-configurable.** `PDFThumbnailCache(maxSize:)` is public (default `defaultPageWindow = 5`); a peek pager passes a larger window (the Android consumer settled on 7).
2. **Eviction cannot invalidate a displayed page.** `RenderedPageCache` eviction releases the kernel's reference only (`onEvict` is a no-op for `PageImage`), and `PageImageHandle` holds its own strong `CGImage`-backed `Image`. Android's recycle-while-painted crash class is structurally absent under ARC; there is nothing to guard.
3. **Adjacent-page prefetch needs no dedicated API.** Peeked pages are real visible views, each rendering through its own `PDFThumbnailViewModel` into the shared lock-guarded per-document cache. Warming beyond the peek is possible with the same public surface (driving a spare `PDFThumbnailViewModel` without mounting a view). If a consumer-measured loading flash ever motivates a first-class prefetch entry, that reopens as a fresh bead — do not add speculative API now.

Android source: `passes-android-main/passes-pdf-ui` (wpass-tjc.3).
