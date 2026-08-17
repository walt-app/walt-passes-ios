import Foundation
import PassesCore
import Testing

@testable import PassesBarcode

/// Pins the QR charset posture (ios-pjs.20, wpass-qj6 analogue, human-approved 2026-08-17):
/// CoreImage emits raw UTF-8 bytes with NO ECI declaration, and iOS keeps that as the
/// de-facto mobile convention rather than hand-rolling an ECI-emitting encoder. These cases
/// prove non-Latin-1 payloads decode back verbatim on the production Vision path. Residual,
/// documented risk: a strictly spec-conformant reader defaults ECI-less symbols to Latin-1
/// and shows mojibake for non-ASCII payloads; ASCII payloads are unambiguous everywhere.
/// See `BarcodeEncoder`'s charset doc and ADR `passes-ui-2`.
@Suite("QR charset round-trip")
struct QrCharsetRoundTripTests {
    private let decoder = VisionBarcodeImageDecoder(
        config: BarcodeDecodeConfig(decodeTimeout: generousDecodeBudget))

    @Test func androidDefectPayloadRoundTripsVerbatim() async {
        // The exact payload that transliterated on Android before wpass-qj6.
        await assertQrRoundTrips("café — naïve — 東京")
    }

    @Test func cjkOnlyPayloadRoundTripsVerbatim() async {
        await assertQrRoundTrips("東京メトロ一日乗車券")
    }

    @Test func supplementaryPlanePayloadRoundTripsVerbatim() async {
        // Outside the BMP; UTF-8 four-byte sequences.
        await assertQrRoundTrips("WALT-\u{1F3AB}-PASS")
    }

    private func assertQrRoundTrips(_ payload: String) async {
        let png = BarcodeImageFactory.qrPNG(payload)
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: payload, format: .qr))
    }
}
