import Foundation
import Testing

@testable import PassesCore

@Suite("PassJsonDecoder")
struct PassJsonDecoderTests {

    private func decode(_ json: String, config: ParserConfig = ParserConfig()) -> PassJsonDecodeResult {
        decodePassJson([(name: PASS_JSON_FILE_NAME, bytes: [UInt8](json.utf8))], config: config)
    }

    private func pass(_ result: PassJsonDecodeResult) -> Pass? {
        if case .ok(let p) = result { return p }
        return nil
    }

    private let minimal = #"{"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o","generic":{}}"#

    @Test func missingEntry() {
        #expect(decodePassJson([], config: ParserConfig()) == .failed(.missing))
    }

    @Test func decodesRequiredFields() {
        let p = pass(decode(minimal))
        #expect(p?.type == .generic)
        #expect(p?.serialNumber == "s")
        #expect(p?.description == "d")
        #expect(p?.organizationName == "o")
    }

    @Test func invalidJson() {
        #expect(decode("not json") == .failed(.invalidJson))
    }

    @Test func missingRequiredFieldIsInvalidShape() {
        let json = #"{"formatVersion":1,"serialNumber":"s","generic":{}}"#
        #expect(decode(json) == .failed(.invalidShape))
    }

    @Test func unknownFormatVersion() {
        let json = #"{"formatVersion":9,"serialNumber":"s","description":"d","organizationName":"o","generic":{}}"#
        #expect(decode(json) == .failed(.unknownFormatVersion(version: 9)))
    }

    @Test func missingFormatVersionIsZero() {
        let json = #"{"serialNumber":"s","description":"d","organizationName":"o","generic":{}}"#
        #expect(decode(json) == .failed(.unknownFormatVersion(version: 0)))
    }

    @Test func twoStylesIsInvalidShape() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "generic":{},"coupon":{}}
            """
        #expect(decode(json) == .failed(.invalidShape))
    }

    @Test func unknownStyleSurfacesRawKey() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "ssoPass":{}}
            """
        #expect(decode(json) == .failed(.unknownPassStyle(raw: "ssoPass")))
    }

    @Test func knownNonStyleObjectKeyDoesNotConfuseStyleResolution() {
        // `nfc` is object-valued but allowlisted; with no style key present it stays unknown
        // with an empty hint (no plausible style candidate).
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "nfc":{"message":"x"}}
            """
        #expect(decode(json) == .failed(.unknownPassStyle(raw: "")))
    }

    @Test func depthLimitTrips() {
        let config = ParserConfig(maxJsonDepth: 2)
        let json = #"{"a":{"b":{"c":1}}}"#
        #expect(decode(json, config: config) == .failed(.jsonDepthExceeded))
    }

    @Test func stringLimitTrips() {
        let config = ParserConfig(maxJsonStringBytes: 3)
        let json = #"{"formatVersion":1,"serialNumber":"toolongvalue","description":"d","organizationName":"o","generic":{}}"#
        #expect(decode(json, config: config) == .failed(.jsonStringTooLong))
    }

    @Test func parsesColorsRgbAndHex() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "foregroundColor":"rgb(255, 0, 0)","backgroundColor":"#00FF00","generic":{}}
            """
        let p = pass(decode(json))
        #expect(p?.colors.foreground == ColorValue(rgb: 0xFF_0000))
        #expect(p?.colors.background == ColorValue(rgb: 0x00FF_00))
    }

    @Test func parsesFields() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "generic":{"primaryFields":[{"key":"k","label":"L","value":"V","textAlignment":"PKTextAlignmentRight"}]}}
            """
        let field = pass(decode(json))?.frontFields.primary.first
        #expect(field?.key == "k")
        #expect(field?.label == "L")
        #expect(field?.value == "V")
        #expect(field?.textAlignment == .right)
    }

    @Test func numericFieldValueStringified() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "generic":{"primaryFields":[{"key":"k","value":42}]}}
            """
        #expect(pass(decode(json))?.frontFields.primary.first?.value == "42")
    }

    @Test func barcodesArrayPreferredOverLegacy() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "barcodes":[{"format":"PKBarcodeFormatQR","message":"m","messageEncoding":"iso-8859-1"}],
             "barcode":{"format":"PKBarcodeFormatPDF417","message":"old","messageEncoding":"utf-8"},
             "generic":{}}
            """
        let barcode = pass(decode(json))?.barcode
        #expect(barcode?.format == .qr)
        #expect(barcode?.message == "m")
    }

    @Test func legacyBarcodeFallback() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "barcode":{"format":"PKBarcodeFormatAztec","message":"old","messageEncoding":"utf-8"},
             "generic":{}}
            """
        #expect(pass(decode(json))?.barcode?.format == .aztec)
    }

    @Test func dangerousFieldsParsedButDropped() {
        // nfc / webServiceURL / authenticationToken present but not surfaced; the pass still
        // decodes successfully.
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "webServiceURL":"https://x","authenticationToken":"secret","nfc":{"message":"m"},
             "generic":{}}
            """
        #expect(pass(decode(json))?.serialNumber == "s")
    }

    @Test func expirationDateParsed() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "expirationDate":"2025-01-01T00:00:00Z","generic":{}}
            """
        #expect(pass(decode(json))?.expirationDate != nil)
    }

    @Test func malformedExpirationDateIsInvalidShape() {
        let json = """
            {"formatVersion":1,"serialNumber":"s","description":"d","organizationName":"o",
             "expirationDate":"not-a-date","generic":{}}
            """
        #expect(decode(json) == .failed(.invalidShape))
    }
}
