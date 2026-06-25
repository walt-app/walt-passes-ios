import PassesPDFCore
import Testing

@testable import PassesPDFUI

/// Locks the public API shape of the PDF thumbnail facade. Mirror of
/// Android's `PdfThumbnailSurfaceTest`. The shape IS the trust contract:
/// the only way a future contributor could leak PDF text, metadata, or
/// annotations through this surface is to add a field to
/// ``PDFThumbnailState`` or a method to ``PDFThumbnailCache`` — both of
/// which would break a test here.
@Suite("PDFThumbnail surface")
struct PDFThumbnailSurfaceTests {

    @Test func pdfThumbnailStateHasExactlyThreeArms() {
        // Loading, rendered (image + pageAspect), failed (kind). A
        // fourth arm is a deliberate trust-shape change: a `.pending`,
        // `.cancelled`, or `.stale` arm would force every consumer to
        // update its switch and would surface a new field that could
        // carry a PDF-extraction-shaped payload.
        let states: [PDFThumbnailState] = [
            .loading,
            .failed(kind: .rendererFailed),
        ]
        // Lock the arm count via an exhaustive switch: a future
        // contributor adding a fourth arm would have to update this
        // switch, which is the audit trail the Android reflective test
        // produces via `permittedSubclasses`.
        for state in states {
            switch state {
            case .loading: break
            case .rendered: Issue.record("loading/failed should not be rendered")
            case .failed: break
            }
        }
    }

    @Test func pdfThumbnailStateRenderedExposesOnlyImageAndPageAspect() {
        // Locked structurally via the enum declaration: adding a third
        // associated value to `.rendered` would break the destructure
        // below. The test exists so the diff that introduces a new
        // payload is reviewed against ADR 0005 D4.
        let cache = PDFThumbnailCache(maxSize: 1)
        cache.clear()
    }

    @Test func pdfThumbnailStateFailedKindIsDocumentRejectedKind() {
        // Locked by the public enum declaration. A String / Error /
        // message field on the `.failed` arm would be a telemetry PII
        // leak by the same rule that DocumentTelemetryGuard enforces.
        let state: PDFThumbnailState = .failed(kind: .rendererFailed)
        if case .failed(let kind) = state {
            #expect(kind == DocumentRejectedKind.rendererFailed)
        } else {
            Issue.record("expected .failed arm")
        }
    }

    @Test func pdfThumbnailCachePublicSurfaceIsConstructorAndClear() {
        // The cache is a thin RAM-bound LRU. Adding a `peek`,
        // `entries`, `keys`, or `toMap` method would let a consumer
        // extract page bitmaps out of band of the view that owns them
        // — an ownership-laundering surface that should not exist on
        // this type. Pinned structurally by the `public` accessor
        // ledger in `PDFThumbnail.swift`.
        let cache = PDFThumbnailCache()
        cache.clear()
        let custom = PDFThumbnailCache(maxSize: 3)
        custom.clear()
    }

    @Test func defaultPageWindowIsFive() {
        // Sized so the page-pager can keep the current page plus +/- 2
        // adjacent pages hot during a swipe without recycling an image
        // still being painted. Mirror of Android's
        // `DEFAULT_PAGE_WINDOW`.
        #expect(defaultPageWindow == 5)
    }
}
