import Foundation
import Testing

@testable import PassesPDF

/// Pins the sub-rect validation rule the renderer enforces before touching
/// PDFKit. Invalid rects fold to ``PassesPDFCore/DocumentRejectedKind/rendererFailed``.
/// Mirrors Android's `SourceRectValidationTest`.
@Suite("SourceRectValidation")
struct SourceRectValidationTests {

    @Test func fullPageIsAlwaysValid() {
        #expect(isSourceRectValid(.fullPage))
    }

    @Test func unitSquareSubRectIsValid() {
        #expect(isSourceRectValid(.subRect(left: 0, top: 0, right: 1, bottom: 1)))
    }

    @Test func centeredQuarterRectIsValid() {
        #expect(isSourceRectValid(.subRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)))
    }

    @Test func zeroAreaSubRectIsRejected() {
        #expect(!isSourceRectValid(.subRect(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5)))
        #expect(!isSourceRectValid(.subRect(left: 0.5, top: 0.25, right: 0.5, bottom: 0.75)))
        #expect(!isSourceRectValid(.subRect(left: 0.25, top: 0.5, right: 0.75, bottom: 0.5)))
    }

    @Test func reversedSubRectIsRejected() {
        #expect(!isSourceRectValid(.subRect(left: 0.75, top: 0.25, right: 0.25, bottom: 0.75)))
        #expect(!isSourceRectValid(.subRect(left: 0.25, top: 0.75, right: 0.75, bottom: 0.25)))
    }

    @Test func outOfUnitSquareSubRectIsRejected() {
        #expect(!isSourceRectValid(.subRect(left: -0.1, top: 0, right: 0.5, bottom: 0.5)))
        #expect(!isSourceRectValid(.subRect(left: 0, top: -0.1, right: 0.5, bottom: 0.5)))
        #expect(!isSourceRectValid(.subRect(left: 0, top: 0, right: 1.1, bottom: 0.5)))
        #expect(!isSourceRectValid(.subRect(left: 0, top: 0, right: 0.5, bottom: 1.1)))
    }

    @Test func nonFiniteSubRectIsRejected() {
        #expect(!isSourceRectValid(.subRect(left: .nan, top: 0, right: 1, bottom: 1)))
        #expect(!isSourceRectValid(.subRect(left: 0, top: 0, right: .infinity, bottom: 1)))
    }
}
