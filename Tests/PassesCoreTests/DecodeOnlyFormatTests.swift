import Foundation
import Testing

@testable import PassesCore

/// The decode-only gate for the widened roster (ios-pjs.15, wpass-pl7.1 analogue): PDF417
/// and Aztec decode but cannot render until ios-pjs.16 wires their writers, so the
/// validator refuses to mint a card and the encoder refuses to encode — both reading the
/// same `ScannableFormatConstraints.decodeOnly` set so the two cannot drift apart.
@Suite("Decode-only formats")
struct DecodeOnlyFormatTests {

    @Test func validatorRefusesADecodeOnlyFormatBeforeFieldChecks() {
        // The format is unusable regardless of what was typed, so the refusal must win
        // even over an empty label / empty payload.
        for format: ScannableFormat in [.pdf417, .aztec] {
            let result = ScannableCardInputValidator.validate(
                input: ScannableCardCreateInput(payload: "", format: format, label: ""),
                id: ScannableCardId("0"),
                createdAt: PassInstant(epochMillis: 0)
            )
            guard case .unsupportedFormat(let refused) = result else {
                Issue.record("\(format) should refuse as unsupportedFormat, got \(result)")
                continue
            }
            #expect(refused == format)
        }
    }

    @Test func decodeOnlyCapsAndCharsetMirrorAndroid() {
        // Byte-capable 2D symbologies: any visible character; caps in characters
        // (1500 Aztec / 800 PDF417, Android wpass-pl7.1 numbers).
        #expect(ScannableFormatConstraints.maxPayloadLength(.aztec) == 1_500)
        #expect(ScannableFormatConstraints.maxPayloadLength(.pdf417) == 800)
        for format: ScannableFormat in [.pdf417, .aztec] {
            #expect(ScannableFormatConstraints.isAllowedChar(format: format, char: "東"))
            #expect(ScannableFormatConstraints.requiredLength(format) == nil)
            #expect(ScannableFormatConstraints.validateStructural(format: format, payload: "x") == nil)
        }
    }

    @Test func encoderRefusesDecodeOnlyFormatsWithoutEchoingThePayload() {
        // Defense in depth below the validator gate: no writer exists for these two in
        // this build, and the refusal detail must stay kernel-authored.
        for format: ScannableFormat in [.pdf417, .aztec] {
            let result = BarcodeEncoder.encode(payload: "M1SYNTHETIC/BCBP", format: format)
            guard case .failure(.writerRejected(let refused, let detail)) = result else {
                Issue.record("\(format) should be refused by the encoder, got \(result)")
                continue
            }
            #expect(refused == format)
            #expect(!detail.contains("M1SYNTHETIC/BCBP"))
        }
    }
}
