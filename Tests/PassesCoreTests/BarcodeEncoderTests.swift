import Foundation
import Testing

@testable import PassesCore

/// Behavior of the kernel's single encode entry point (wpass-1kg analogue). The roster
/// happy paths, the pre-writer refusals (empty payload, proactive QR density), the
/// over-rejection guards that keep the density check from firing on payloads a denser
/// QR mode can hold, and the promise that a failure `detail` never echoes the payload.
@Suite("BarcodeEncoder")
struct BarcodeEncoderTests {

    // MARK: - Happy paths

    @Test func coreImageFormatsEncodeToAnImage() {
        for (format, payload): (ScannableFormat, String) in [
            (.qr, "WALT-MEMBER-0042"), (.code128, "WALT-0042"),
        ] {
            let result = BarcodeEncoder.encode(payload: payload, format: format)
            guard case .success(.image) = result else {
                Issue.record("\(format) should encode to a CoreImage-backed image, got \(result)")
                continue
            }
        }
    }

    @Test func oneDimensionalFormatsEncodeToAMatrix() {
        for (format, payload): (ScannableFormat, String) in [
            (.ean13, "4006381333931"), (.upcA, "036000291452"), (.code39, "WALT 39"),
        ] {
            let result = BarcodeEncoder.encode(payload: payload, format: format)
            guard case .success(.matrix(let matrix)) = result else {
                Issue.record("\(format) should encode to a module matrix, got \(result)")
                continue
            }
            #expect(matrix.height == 1, "1D symbols are single-row")
            #expect(matrix.width > 0)
        }
    }

    // MARK: - Proactive QR density refusal

    @Test func qrMultibytePayloadOverByteModeCeilingIsTooDense() {
        // 800 CJK characters clear the 2000-char validator cap but weigh 2400 UTF-8
        // bytes — past the v40-M byte-mode ceiling. This is the wpass-1kg gap payload.
        let payload = String(repeating: "東", count: 800)
        let result = BarcodeEncoder.encode(payload: payload, format: .qr)
        guard case .failure(.payloadTooDense) = result else {
            Issue.record("over-ceiling multibyte QR payload should be payloadTooDense, got \(result)")
            return
        }
    }

    @Test func qrAlphanumericPayloadOverTheByteCeilingStillEncodes() {
        // Over-rejection guard for the alphanumeric-mode gate itself: 2400 chars weigh
        // 2400 bytes — past the byte-mode ceiling — but fit alphanumeric mode (~3,391
        // chars at v40-M). Simplifying refuseBeforeWriter to a bare byte-count check
        // turns this payload into a false payloadTooDense.
        let payload = String(repeating: "A", count: 2_400)
        let result = BarcodeEncoder.encode(payload: payload, format: .qr)
        guard case .success = result else {
            Issue.record("over-ceiling alphanumeric QR payload should encode, got \(result)")
            return
        }
    }

    @Test func qrFullCapByteModePayloadUnderCeilingStillEncodes() {
        // Lowercase ASCII forces byte mode; 2000 chars is 2000 bytes, under the
        // 2331-byte v40-M ceiling, so the pre-check must not fire.
        let payload = String(repeating: "walt", count: 500)
        let result = BarcodeEncoder.encode(payload: payload, format: .qr)
        guard case .success = result else {
            Issue.record("2000-byte byte-mode QR payload should encode, got \(result)")
            return
        }
    }

    // MARK: - Writer refusals

    @Test func emptyPayloadIsRefusedForEveryFormat() {
        // Defense in depth below the validator: refusal must be uniform here, not five
        // incidental generator behaviors (CoreImage happily encodes an empty QR).
        for format in ScannableFormat.allCases {
            let result = BarcodeEncoder.encode(payload: "", format: format)
            guard case .failure(.writerRejected(let failed, _)) = result else {
                Issue.record("\(format) should refuse an empty payload, got \(result)")
                continue
            }
            #expect(failed == format)
        }
    }

    @Test func code128NonAsciiPayloadIsWriterRejected() {
        // The validator blocks this upstream; the encoder still refuses defensively.
        let result = BarcodeEncoder.encode(payload: "café", format: .code128)
        guard case .failure(.writerRejected(let format, _)) = result else {
            Issue.record("non-ASCII Code128 payload should be writer-rejected, got \(result)")
            return
        }
        #expect(format == .code128)
    }

    @Test func oneDimensionalStructuralFailureIsWriterRejected() {
        // Wrong EAN-13 check digit: the 1D encoder's defensive re-check refuses rather
        // than rendering a symbol that scans to a different payload.
        let result = BarcodeEncoder.encode(payload: "4006381333930", format: .ean13)
        guard case .failure(.writerRejected(let format, _)) = result else {
            Issue.record("bad check digit should be writer-rejected, got \(result)")
            return
        }
        #expect(format == .ean13)
    }

    // MARK: - Detail hygiene

    @Test func writerRejectedDetailNeverEchoesThePayload() {
        // `detail` is the one string that crosses the kernel boundary on this surface;
        // it must never carry the payload back out (mirror of Android's withoutPayload pin).
        let failures: [(String, ScannableFormat)] = [
            ("café", .code128),
            ("4006381333930", .ean13),
            ("036000291453", .upcA),
            ("lowercase not in code39", .code39),
        ]
        for (payload, format) in failures {
            guard
                case .failure(.writerRejected(_, let detail)) =
                    BarcodeEncoder.encode(payload: payload, format: format)
            else {
                Issue.record("\(format) should writer-reject \(payload)")
                continue
            }
            #expect(!detail.contains(payload), "\(format) detail must not echo the payload")
        }
    }
}
