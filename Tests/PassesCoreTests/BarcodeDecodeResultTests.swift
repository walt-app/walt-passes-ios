import Foundation
import Testing

@testable import PassesCore

@Suite("BarcodeDecodeResult")
struct BarcodeDecodeResultTests {

    @Test func armsAreReachableViaSwitch() {
        let result: BarcodeDecodeResult = .noBarcodeFound
        let branch: String
        switch result {
        case .decodedBarcode: branch = "decodedBarcode"
        case .noBarcodeFound: branch = "noBarcodeFound"
        case .decodeFailed: branch = "decodeFailed"
        }
        #expect(branch == "noBarcodeFound")
    }

    @Test func decodedBarcodeCarriesPayloadAndFormatFaithfully() {
        let result: BarcodeDecodeResult = .decodedBarcode(payload: "ABC-123", format: .qr)
        guard case .decodedBarcode(let payload, let format) = result else {
            Issue.record("expected decodedBarcode arm")
            return
        }
        #expect(payload == "ABC-123")
        #expect(format == .qr)
    }

    @Test func decodeFailedBucketsTheReason() {
        let result: BarcodeDecodeResult = .decodeFailed(reason: .imageTooLarge)
        guard case .decodeFailed(let reason) = result else {
            Issue.record("expected decodeFailed arm")
            return
        }
        #expect(reason == .imageTooLarge)
    }

    @Test func armsAreEquatable() {
        #expect(
            BarcodeDecodeResult.decodedBarcode(payload: "x", format: .code128)
                == .decodedBarcode(payload: "x", format: .code128)
        )
        #expect(
            BarcodeDecodeResult.decodedBarcode(payload: "x", format: .code128)
                != .decodedBarcode(payload: "y", format: .code128)
        )
        #expect(BarcodeDecodeResult.noBarcodeFound == .noBarcodeFound)
        #expect(
            BarcodeDecodeResult.decodeFailed(reason: .sourceUnreadable)
                != .decodeFailed(reason: .decoderUnavailable)
        )
    }

    @Test func decodeFailureReasonHasAllFiveBuckets() {
        #expect(DecodeFailureReason.allCases.count == 5)
        #expect(
            Set(DecodeFailureReason.allCases) == [
                .sourceUnreadable,
                .imageDecodeFailed,
                .imageTooLarge,
                .unsupportedBarcodeFormat,
                .decoderUnavailable,
            ]
        )
    }
}
