import Foundation
import Testing
import Vision

@testable import PassesBarcode
@testable import PassesCore

/// Decode-roster growth to Aztec + PDF417 (ios-pjs.15, wpass-pl7.1 analogue): boarding
/// passes are imported as screenshots, which have no PKPASS to arrive in, so both
/// symbologies must be decodable from still images. Payloads are synthetic BCBP-shaped
/// strings; no real boarding-pass data enters the repository.
@Suite("Aztec + PDF417 decode roster")
struct AztecPdf417DecodeTests {
    private let decoder = VisionBarcodeImageDecoder(
        config: BarcodeDecodeConfig(decodeTimeout: generousDecodeBudget))

    private let syntheticBcbp = "M1DOE/JANE MS EABC123 WLTCPHSK 0042 229Y012A0001 100"

    @Test func aztecSymbolDecodesToTheAztecFormat() async {
        let png = BarcodeImageFactory.aztecPNG(syntheticBcbp)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: syntheticBcbp, format: .aztec))
    }

    @Test func pdf417SymbolDecodesToThePdf417Format() async {
        let png = BarcodeImageFactory.pdf417PNG(syntheticBcbp)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: syntheticBcbp, format: .pdf417))
    }

    @Test func largeScreenshotScaleDecodesWithoutARescaleLadder() async {
        // Android needed a bounded multi-scale ladder (wpass-pl7.2) because ZXing is
        // single-scale and the probe artifact decoded only at <=1600px. Vision does its
        // own multi-scale detection; this pins that a screenshot-sized (~3000px) render
        // decodes directly, which is the evidence the iOS port needs no ladder.
        let png = BarcodeImageFactory.aztecPNG(syntheticBcbp, scale: 60)
        #expect(
            await decoder.decode(source: .data(png))
                == .decodedBarcode(payload: syntheticBcbp, format: .aztec))
    }

    @Test func requestedAllowlistIsExactlyTheRosterSymbologies() {
        // The allowlist is the parser-surface bound the threat model leans on: nothing
        // outside it is ever requested from Vision, so DataMatrix (the deliberate
        // non-member) stays unreachable. UPC-A rides Vision's EAN-13 arm.
        #expect(
            Set(RosterSymbology.requested) == [.qr, .code128, .ean13, .code39, .aztec, .pdf417])
    }

    @Test func upcAFoldingSurvivesTheWiderRoster() {
        let folded = RosterSymbology.fold(symbology: .ean13, payload: "0036000291452")
        #expect(folded?.format == .upcA)
        #expect(folded?.payload == "036000291452")
    }
}
