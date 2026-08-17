import Foundation
import PassesCore
import Testing

@testable import PassesBarcode

/// Pins the QR charset posture (ios-pjs.20, wpass-qj6 analogue; full record in ADR
/// `passes-ui-2`, human-approved 2026-08-17): non-Latin-1 payloads round-trip verbatim
/// through the production `BarcodeEncoder` -> Vision path, proving both ends agree on
/// UTF-8. The ECI-absence half of the posture is pinned by
/// `qrByteModeCeilingIsExactAtTheBoundary` (an emitted ECI header would cost the 2331st
/// byte), not here — Vision decodes symbols with and without the header alike. Distinct
/// from `HostilePayloadFidelityTests`, which pins decode faithfulness on hostile content;
/// this suite pins the charset contract.
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
        // Encode through the production BarcodeEncoder, not the factory's test-local
        // generator, so a charset change in the real encoder fails these tests.
        guard case .success(.image(let symbol)) = BarcodeEncoder.encode(payload: payload, format: .qr)
        else {
            Issue.record("production encoder should encode \(payload)")
            return
        }
        let png = BarcodeImageFactory.png(symbol: symbol)
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: payload, format: .qr))
    }
}
