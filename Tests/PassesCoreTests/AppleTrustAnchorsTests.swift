import Foundation
import Testing

@testable import PassesCore

@Suite("AppleTrustAnchors")
struct AppleTrustAnchorsTests {

    @Test func loadsThreeBundledRoots() throws {
        let anchors = try AppleTrustAnchors.trustAnchors()
        #expect(anchors.count == 3)
    }

    @Test func loadsTwoBundledIntermediates() throws {
        let intermediates = try AppleTrustAnchors.knownIntermediates()
        #expect(intermediates.count == 2)
    }

    @Test func filenameListsMatchLoadedCounts() {
        #expect(AppleTrustAnchors.bundledTrustAnchorFilenames.count == 3)
        #expect(AppleTrustAnchors.bundledIntermediateFilenames.count == 2)
    }

    @Test func anchorsAreDistinct() throws {
        let anchors = try AppleTrustAnchors.trustAnchors()
        let subjects = Set(anchors.map { $0.subject.description })
        #expect(subjects.count == anchors.count)
    }
}
