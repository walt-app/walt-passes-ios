import Foundation
import Testing

@testable import PassesCore

/// The Latin-1 charset posture for the byte-capable 2D pair (ios-pjs.16, §7-approved
/// 2026-08-17): CoreImage's Aztec/PDF417 generators cannot declare a charset, and Vision
/// (like every spec-conformant reader) interprets their ECI-less bytes as ISO-8859-1 — so
/// the kernel encodes Latin-1 bytes and the validator admits only Latin-1-representable
/// characters for these two formats. Full record: ADR `barcode-decode-1`.
@Suite("Aztec/PDF417 Latin-1 charset posture")
struct AztecPdf417CharsetTests {

    @Test func validatorAcceptsLatin1AndRefusesBeyond() {
        for format: ScannableFormat in [.pdf417, .aztec] {
            #expect(ScannableFormatConstraints.isAllowedChar(format: format, char: "A"))
            #expect(ScannableFormatConstraints.isAllowedChar(format: format, char: "é"))
            #expect(ScannableFormatConstraints.isAllowedChar(format: format, char: "ÿ"))
            #expect(!ScannableFormatConstraints.isAllowedChar(format: format, char: "東"))
            #expect(!ScannableFormatConstraints.isAllowedChar(format: format, char: "—"))
            #expect(!ScannableFormatConstraints.isAllowedChar(format: format, char: "🎫"))
        }
        // QR keeps its any-character posture (UTF-8 auto-detection holds there).
        #expect(ScannableFormatConstraints.isAllowedChar(format: .qr, char: "東"))
    }

    @Test func validatorMintsACardForALatin1Payload() {
        for format: ScannableFormat in [.pdf417, .aztec] {
            let result = ScannableCardInputValidator.validate(
                input: ScannableCardCreateInput(
                    payload: "M1DOE/JANE MS EABC123", format: format, label: "Flight"),
                id: ScannableCardId("0"),
                createdAt: PassInstant(epochMillis: 0)
            )
            guard case .success = result else {
                Issue.record("\(format) ASCII payload should validate, got \(result)")
                continue
            }
        }
    }

    @Test func validatorRefusesCjkWithWrongCharsetNotUnsupportedFormat() {
        let result = ScannableCardInputValidator.validate(
            input: ScannableCardCreateInput(payload: "東京", format: .aztec, label: "Card"),
            id: ScannableCardId("0"),
            createdAt: PassInstant(epochMillis: 0)
        )
        guard case .invalidPayload(.wrongCharset(let format, _)) = result else {
            Issue.record("CJK aztec payload should be wrongCharset, got \(result)")
            return
        }
        #expect(format == .aztec)
    }

    @Test func encoderRefusesANonLatin1PayloadDefensively() {
        // The validator blocks these upstream; the encoder still refuses rather than
        // minting a symbol that scans to mojibake, and never echoes the payload.
        for format: ScannableFormat in [.pdf417, .aztec] {
            let result = BarcodeEncoder.encode(payload: "東京メトロ", format: format)
            guard case .failure(.writerRejected(let refused, let detail)) = result else {
                Issue.record("\(format) CJK payload should be writer-rejected, got \(result)")
                continue
            }
            #expect(refused == format)
            #expect(!detail.contains("東京メトロ"))
        }
    }

    @Test func writersEncodeAtTheFullCap() {
        // Over-rejection guard: the caps (1500 Aztec / 800 PDF417) sit under the measured
        // CoreImage capacities at the pinned EC levels (2674 / 1823 single-byte chars), so
        // a cap-length payload — including high-Latin-1 chars, one byte each in ISO-8859-1
        // — must encode.
        let aztec = BarcodeEncoder.encode(
            payload: String(repeating: "é", count: 1_500), format: .aztec)
        guard case .success(.image) = aztec else {
            Issue.record("cap-length aztec payload should encode, got \(aztec)")
            return
        }
        let pdf417 = BarcodeEncoder.encode(
            payload: String(repeating: "é", count: 800), format: .pdf417)
        guard case .success(.image) = pdf417 else {
            Issue.record("cap-length pdf417 payload should encode, got \(pdf417)")
            return
        }
    }
}
