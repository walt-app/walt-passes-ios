import Foundation
import Testing

@testable import PassesCore

@Suite("ScannableCardCreateResult")
struct ScannableCardCreateResultTests {

    @Test func armsAreReachableViaSwitch() {
        let result: ScannableCardCreateResult = .invalidPayload(reason: .empty)
        let branch: String
        switch result {
        case .success: branch = "success"
        case .invalidPayload: branch = "invalidPayload"
        case .invalidLabel: branch = "invalidLabel"
        case .unsupportedFormat: branch = "unsupportedFormat"
        case .encoderFailure: branch = "encoderFailure"
        }
        #expect(branch == "invalidPayload")
    }

    @Test func payloadRejectionArmsAreAllConstructible() {
        let rejections: [PayloadRejection] = [
            .tooLong(actual: 100, max: 80),
            .wrongCharset(format: .ean13, offendingChar: "A"),
            .wrongLength(actual: 11, required: 13, format: .ean13),
            .invalidCheckDigit(format: .upcA),
            .containsControlChar,
            .containsBidiChar,
            .empty,
        ]
        #expect(rejections.count == 7)
    }

    @Test func labelRejectionArmsAreAllConstructible() {
        let rejections: [LabelRejection] = [
            .tooLong(actual: 100, max: 32),
            .containsBidiChar,
            .containsControlChar,
            .empty,
        ]
        #expect(rejections.count == 4)
    }

    @Test func encoderFailureReasonArmsAreAllConstructible() {
        let reasons: [EncoderFailureReason] = [
            .writerRejected(format: .qr, detail: "boom"),
            .payloadTooDense,
        ]
        #expect(reasons.count == 2)
    }
}
