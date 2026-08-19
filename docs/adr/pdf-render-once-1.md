# pdf-render-once-1: Import-time page rasterisation; display never re-parses originals

Status: accepted (ios-dts.16, §7-approved by human 2026-08-18 — record on walt-ios bead ios-dts.2)
Date: 2026-08-18

## Context

The iOS kernel parses untrusted PDFs **in-process** with PDFKit/CoreGraphics
(`data-passes-1` records the accepted deviation from Android's isolated
`:pdfRenderer`). PDF is the compound, compute-bearing format of the roster —
JBIG2/JPX filters, embedded fonts; the FORCEDENTRY class — and the pre-change
display path re-parsed the **original untrusted bytes on every detail open**
(`DocumentView` / `FullScreenDocumentView` drove `PDFRendererBinder` live),
with a watchdog whose iOS `ProcessKiller` is a documented no-op. A 2026-08-18
§7 review, pricing the residual against a soon-payment-capable device, judged
the repeated in-process parse the app's worst-contained untrusted-parse
surface and directed this hardening ahead of the image-document epic.

## Decision

**Render once, retain rasters.** At import, `DefaultPDFImporter` rasterises
every page (≤ `maxPages` 10) via the new `PDFRendererBinder.renderFitted` —
aspect-correct dimensions fitted within the existing 4 MP budget
(`pageRasterMaxPixels` = `PDFKitRenderer.maxPixels`) — PNG-encodes each, and
hands the complete set to `persist` — via `renderAllFitted`, which opens the
`PDFDocument` once for the whole pass (import performs a bounded handful of
parses: probe, the page-zero thumbnail render, and one batch pass — never one
per page, and never any on display). Any page failing to render or encode
rejects the whole import (a partially-rasterised document would reintroduce
the re-parse path). Storage lands the set in the same transaction as the
document row (`document_page_rasters`, schema v6, cascade delete; count and
per-raster pixel bound re-checked as `pageRastersInvalidAtStorage`).

**Display consumes stored rasters only.** `DocumentView` /
`FullScreenDocumentView` take a `DocumentPageSource` (PassesPDFCore) instead
of `pdfData` + renderer; `PDFThumbnailViewModel` decodes the stored
first-party PNG. Structurally enforced twice: `PassesPDFUI` **dropped its
`PassesPDF` dependency** (the renderer seam no longer resolves at compile
time), and `RenderOnceGuardTests` source-scans the module for any
re-introduction (`import PDFKit`, `PDFDocument(data`, `PDFRendererBinder`,
`CGPDFDocument`).

**One sanctioned fallback.** `RerenderOnMissPageSource` (PassesPDF) serves a
store miss — a legacy pre-v6 document or a lost blob — with exactly one
bounded re-render of the originals per miss, persists the backfill through
the **per-page** `insertDocumentPageRaster` (pre-v6 pages recover one open at
a time; the full-set write can never be assembled from single misses), and
never retries in a loop. Concurrent misses are coalesced per page and
serialized across pages, so at most one parse of the originals runs at a
time; render failures report `onConsumerRenderFailed` rather than vanishing.
Steady state: the untrusted bytes meet a PDF parser only at import, never on
display, and a legacy document converges page by page as it is viewed (one
bounded re-render per missed page).

## Consequences

- Hostile-parse events per document collapse from N-per-open to
  import-time-only (plus at most one lazy backfill for pre-v6 rows).
- Zoom fidelity IMPROVES: the former full-screen path requested slot
  dimensions in points (~0.3 MP on a 6.1-inch phone) and zoomed that via
  `scaleEffect` (its sub-rect-re-render doc comment was stale); stored
  rasters carry the full 4 MP budget, decoded at the 2048 px ceiling. The
  fitted render also fixes the former slot-stretch distortion — pages are
  now aspect-correct.
- Storage grows by the raster set (PNG of ≤ 4 MP per page, ≤ 10 pages);
  text-heavy pages compress well, scanned-photo PDFs may exceed the original's
  size — bounded by `DocumentBounds.maxRasterBytes` (20 MiB per raster; a PNG
  materially above the 16 MiB raw-RGBA size is pathological). Accepted;
  revisit the codec only if real. Import peak memory holds the accumulating
  encoded PNGs plus ONE ~16 MiB render buffer — the streaming `renderAllFitted`
  contract encodes-and-releases each page's raw buffer before the next page
  renders. Accepted for the 10-page cap, not a shape to grow past it.
- Display surfaces decode to what they can show, off the main actor: the
  inline pager caps the decoded longer side (`DocumentView.inlineMaxPixelSize`,
  1200 px — ~20 MB of cache across `defaultPageWindow` instead of ~80 MB at
  full budget); the full-screen surface caps at
  `fullScreenMaxPixelSize` (2048 px) because the stored dimensions are
  caller-declared and never verified against the blob, so the decode carries
  its own ceiling. Both decode the same first-party bytes — render-once is
  untouched.
- A document's raster set is bounded in aggregate
  (`DocumentBounds.maxTotalRasterBytes`, 4x the 25 MiB source cap) on both
  write paths, on top of the per-raster pixel and byte caps.
- `renderFitted`/`renderAllFitted` land with fail-closed protocol-extension
  defaults, so the `PDFRendererBinder` additions are not source-breaking for
  out-of-package conformers.
- The fit derives from `bounds(for: .mediaBox)`, which ignores `/Rotate`,
  while `page.draw` applies it — pre-existing behaviour, but any residual
  squash on rotated pages is now baked into storage rather than recomputed
  per open. The mediaBox is attacker-controlled geometry: `fittedDimensions`
  clamps every value into `[1, maxPixels]` before integer conversion and
  derives width from the integer budget (no correction loop), so degenerate
  aspects cost O(1) and cannot trap.
- **iOS-only deviation from Android** (human-approved 2026-08-18): Android
  re-renders per open inside its isolated sandbox and stores no rasters. The
  iOS schema chain therefore runs one version ahead from v6 on (iOS v7/v8
  will mirror Android v6/v7 — see `Schema.swift`).
- The importer's page-zero 600×800 thumbnail leg is unchanged
  (`document_thumbnails` consumers untouched).
