import Foundation
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
@MainActor
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

    /// Every per-arm document view composes the caption unconditionally —
    /// there is no placement parameter and no arm may omit it. Source-pinned
    /// (the iOS stand-in for Android's Compose-tree assertion): each private
    /// arm struct's section of DocumentView.swift must construct
    /// `DocumentTrustCaption()`.
    @Test func everyDocumentArmComposesTheTrustCaption() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PassesPDFUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/PassesPDFUI/DocumentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for arm in ["struct PdfDocumentView", "struct ImageDocumentView"] {
            guard let armRange = text.range(of: arm) else {
                Issue.record("\(arm) not found — reconcile this pin with the rename")
                continue
            }
            let tail = text[armRange.upperBound...]
            let nextStruct = tail.range(of: "\nprivate struct ")
            let body = nextStruct.map { tail[..<$0.lowerBound] } ?? tail
            #expect(
                body.contains("DocumentTrustCaption()"),
                "\(arm) does not compose the non-suppressible trust caption")
        }
    }
}
