import CoreVideo
import Foundation
import ImageIO
import PassesCore
import Testing

@testable import PassesBarcode

/// Behavioural coverage for ``VisionBarcodeFrameDecoder``: the roster round-trip off a live
/// `CVPixelBuffer` (benign payloads decode to the right format), the empty-frame path, and the
/// `orientation` plumbing (the iOS analogue of Android's `reverseHorizontal` front-camera flag).
/// The adversarial faithfulness corpus is its own suite, ``FrameHostilePayloadFidelityTests``.
///
/// Every case synthesises the frame with ``BarcodeFrameFactory`` and decodes it through the
/// production decoder — the same pixel→symbol path the consumer's per-frame analyzer runs, minus
/// the `CMSampleBuffer` capture glue the app strips before calling in.
@Suite("VisionBarcodeFrameDecoder")
struct VisionBarcodeFrameDecoderTests {
    private let decoder = VisionBarcodeFrameDecoder()

    @Test func decodesQrFromFrame() async {
        let frame = BarcodeFrameFactory.qrFrame("WALT-LIVE-12345")
        #expect(await decoder.decode(frame: frame) == .decodedBarcode(payload: "WALT-LIVE-12345", format: .qr))
    }

    @Test func decodesCode128FromFrame() async {
        let frame = BarcodeFrameFactory.code128Frame("A1B2C3D4")
        #expect(await decoder.decode(frame: frame) == .decodedBarcode(payload: "A1B2C3D4", format: .code128))
    }

    @Test func blankFrameHasNoBarcode() async {
        let frame = BarcodeFrameFactory.blankFrame(width: 400, height: 400)
        #expect(await decoder.decode(frame: frame) == .noBarcodeFound)
    }

    @Test func nonUpOrientationIsAcceptedAndDecodes() async {
        // The `orientation` argument (Android's `reverseHorizontal` analogue) must be plumbed to the
        // request handler without breaking the decode. `VNDetectBarcodesRequest` is orientation-
        // invariant, so this asserts the parameter is *accepted and harmless* on a normal frame, not
        // that it is what enables the decode (see the decoder's "provided for correctness" note).
        let frame = BarcodeFrameFactory.code128Frame("LOYALTY-9931")
        let result = await decoder.decode(frame: frame, orientation: .upMirrored)
        #expect(result == .decodedBarcode(payload: "LOYALTY-9931", format: .code128))
    }

    @Test func explicitUpOrientationMatchesConvenienceDefault() async {
        // The convenience `decode(frame:)` overload must be exactly `orientation: .up`.
        let frame = BarcodeFrameFactory.qrFrame("ORIENT-UP")
        let explicit = await decoder.decode(frame: frame, orientation: .up)
        let convenience = await decoder.decode(frame: frame)
        #expect(explicit == .decodedBarcode(payload: "ORIENT-UP", format: .qr))
        #expect(explicit == convenience)
    }
}
