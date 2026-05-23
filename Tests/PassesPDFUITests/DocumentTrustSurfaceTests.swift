import Testing

@testable import PassesPDFUI

/// Trust-claim-bearing surface assertions. Mirror of Android's
/// `DocumentTrustSurfaceTest`. The Robolectric-driven Compose-tree
/// assertions on Android cannot run from a plain Swift test target; the
/// load-bearing assertion — the displayed string MUST be the exact value
/// of the verbatim constant — is testable here without rendering.
///
/// View-construction smoke is covered in `ViewConstructionSmokeTests`.
@Suite("Document trust surface")
struct DocumentTrustSurfaceTests {

    @Test func trustCaptionTextMatchesVerbatimWording() {
        // The non-suppressible caption is the trust contract for
        // documents (ADR 0005 D5: PDFs are never signature-verified).
        // The visible string IS the audit surface; locking it here means
        // a contributor cannot soften the wording without updating the
        // test.
        #expect(
            DocumentTrustCaption.trustCaptionText
                == "User-provided document. Walt has not verified the source."
        )
    }

    @Test func documentTileBadgeLabelIsDocument() {
        // The "Document" badge sets the artifact class apart from
        // signed passes at a glance. Locking it here means a future
        // refactor that drops the badge cannot do so silently.
        #expect(DocumentTile.documentBadgeText == "Document")
    }

    @Test func documentsLaneHeaderLabelIsDocuments() {
        #expect(DocumentsLane.laneHeaderText == "Documents")
    }
}
