import PassesCore
import Testing

@testable import PassesUI

/// Pins the four-arm rejection copy (mirror of Android's `rejectionCopy`). The
/// arms must stay distinct: tampered is a security disclosure, malformed is a
/// structural error, and coalescing them defeats the lenient-with-disclosure
/// signature policy (decision-wlt-0tn-q1 1a).
@Suite("PassImportRejectionSheet copy")
struct PassImportRejectionSheetTests {

    @Test func tamperedCopyDisclosesTheSecurityEvent() {
        let copy = PassImportRejectionSheet.rejectionCopy(.tampered)
        #expect(copy.title == "This pass appears to have been tampered with")
        #expect(copy.body == "The signature does not match the file's contents. Walt did not save this pass.")
    }

    @Test func malformedCopyIsStructuralNotSecurity() {
        let copy = PassImportRejectionSheet.rejectionCopy(.malformed)
        #expect(copy.title == "This file is not a valid pass")
        #expect(copy.body == "Walt could not read this file as a PKPASS archive.")
    }

    @Test func unsupportedCopy() {
        let copy = PassImportRejectionSheet.rejectionCopy(.unsupported)
        #expect(copy.title == "Walt cannot open this pass")
        #expect(copy.body == "This pass uses a format Walt does not support.")
    }

    @Test func resourceLimitCopy() {
        let copy = PassImportRejectionSheet.rejectionCopy(.resourceLimitExceeded)
        #expect(copy.title == "This pass is too large to open safely")
        #expect(copy.body == "The pass exceeded Walt's safety limits and was not loaded.")
    }

    @Test func everyArmHasDistinctCopy() {
        let copies = ParseFailureKind.allCases.map { PassImportRejectionSheet.rejectionCopy($0) }
        #expect(Set(copies.map(\.title)).count == copies.count)
        #expect(Set(copies.map(\.body)).count == copies.count)
    }
}
