import Foundation
import Testing

@testable import PassesBarcode
@testable import PassesCore

/// Pins the Latin-1 charset posture end to end (ios-pjs.16, §7-approved 2026-08-17):
/// payloads encoded by the production `BarcodeEncoder` — which writes ISO-8859-1 bytes
/// for these two symbologies, the spec default every ECI-less reader assumes — decode
/// back verbatim through the production Vision path, including the high-Latin-1 range
/// that UTF-8 bytes corrupted ("café" read back as "cafÃ©" before the posture).
@Suite("Aztec/PDF417 charset round-trip")
struct AztecPdf417CharsetRoundTripTests {
    private let decoder = VisionBarcodeImageDecoder(
        config: BarcodeDecodeConfig(decodeTimeout: generousDecodeBudget))

    @Test func asciiBcbpPayloadRoundTripsVerbatim() async {
        await assertRoundTrips("M1DOE/JANE MS EABC123 WLTCPHSK 0042 229Y012A0001 100")
    }

    @Test func highLatin1PayloadRoundTripsVerbatim() async {
        await assertRoundTrips("café naïve smörgåsbord ÀÿÞ±")
    }

    private func assertRoundTrips(_ payload: String) async {
        for format: ScannableFormat in [.aztec, .pdf417] {
            guard case .success(.image(let symbol)) = BarcodeEncoder.encode(payload: payload, format: format)
            else {
                Issue.record("production encoder should encode \(payload) as \(format)")
                continue
            }
            let png = BarcodeImageFactory.png(symbol: symbol)
            #expect(
                await decoder.decode(source: .data(png))
                    == .decodedBarcode(payload: payload, format: format))
        }
    }
}
