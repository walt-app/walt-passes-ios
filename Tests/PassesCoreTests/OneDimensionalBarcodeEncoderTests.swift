import Testing

@testable import PassesCore

/// Structural pins for ``OneDimensionalBarcodeEncoder``. The full correctness
/// proof is the Vision decode round-trip in `PassesBarcodeTests/OneDRoundTripTests`
/// (encode → rasterize → production decode → payload equality); these tests pin
/// the spec-derivable structure that a table transcription error would break.
@Suite("OneDimensionalBarcodeEncoder")
struct OneDimensionalBarcodeEncoderTests {

    // "4006381333931": the standard EAN-13 example (check digit 1).
    private let ean13Fixture = "4006381333931"
    // "036000291452": published UPC-A example with valid check digit.
    private let upcAFixture = "036000291452"

    // MARK: - EAN-13

    @Test func ean13Has95SymbolModulesPlusQuietZones() throws {
        let matrix = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: ean13Fixture, format: .ean13))
        // 11-module left quiet zone + 95-module symbol + 7-module right quiet zone.
        #expect(matrix.width == 113)
        #expect(matrix.height == 1)
        expectGuards(matrix, quietLeft: 11, quietRight: 7)
    }

    @Test func ean13RejectsWrongCheckDigit() {
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "4006381333930", format: .ean13) == nil)
    }

    @Test func ean13RejectsWrongLengthAndCharset() {
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "40063813339", format: .ean13) == nil)
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "40063813339AB", format: .ean13) == nil)
    }

    // MARK: - UPC-A

    @Test func upcAHas95SymbolModulesPlusQuietZones() throws {
        let matrix = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: upcAFixture, format: .upcA))
        // 9-module quiet zones per side around the 95-module symbol.
        #expect(matrix.width == 113)
        expectGuards(matrix, quietLeft: 9, quietRight: 9)
    }

    @Test func upcAMatchesLeadingZeroEan13Symbol() throws {
        // The UPC-A symbol IS the EAN-13 symbol for "0" + payload; only the
        // quiet zones differ (9/9 vs 11/7). Comparing the stripped symbols
        // pins the subset relationship the decoder's fold relies on.
        let upcA = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: upcAFixture, format: .upcA))
        let ean13 = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: "0" + upcAFixture, format: .ean13))
        let upcASymbol = (9..<(9 + 95)).map { upcA.isSet(x: $0, y: 0) }
        let ean13Symbol = (11..<(11 + 95)).map { ean13.isSet(x: $0, y: 0) }
        #expect(upcASymbol == ean13Symbol)
    }

    @Test func upcARejectsWrongCheckDigitAndCharset() {
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "036000291453", format: .upcA) == nil)
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "03600029145A", format: .upcA) == nil)
    }

    // MARK: - Code 39

    @Test func code39WidthMatchesCharacterArithmetic() throws {
        // 9 payload chars + 2 start/stop = 11 characters. Each character is
        // 12 modules (3 wide x 2 + 6 narrow x 1), separated by 10 one-module
        // gaps, inside 10-module quiet zones: 11*12 + 10 + 20 = 162.
        let matrix = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: "HELLO-123", format: .code39))
        #expect(matrix.width == 162)
        expectGuards(matrix, quietLeft: 10, quietRight: 10)
    }

    @Test func code39RejectsCharsOutsideItsAlphabet() {
        // '*' is start/stop-only; lowercase is outside the Code 39 alphabet.
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "AB*CD", format: .code39) == nil)
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "hello", format: .code39) == nil)
    }

    @Test func code39AlphabetAgreesWithFormatConstraints() {
        // The encoder's table and the validator's charset must accept the same
        // characters — a card the validator accepts must never hit the render
        // fallback for a missing table entry.
        let alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%"
        for char in alphabet {
            #expect(ScannableFormatConstraints.isAllowedChar(format: .code39, char: char))
            #expect(
                OneDimensionalBarcodeEncoder.encode(payload: String(char), format: .code39) != nil,
                "encoder table missing '\(char)'")
        }
    }

    @Test func code39EveryEncodingHasExactlyThreeWideElements() {
        // Code 39's name: 3 of 9 elements are wide. A transcription slip in
        // the table almost always breaks this invariant.
        for encoding in OneDimensionalBarcodeEncoder.code39AllEncodings {
            #expect(encoding.nonzeroBitCount == 3, "encoding \(encoding) is not 3-of-9")
        }
    }

    // MARK: - Shared contract

    @Test func emptyAndUnsupportedFormatsReturnNil() {
        for format in [ScannableFormat.ean13, .upcA, .code39] {
            #expect(OneDimensionalBarcodeEncoder.encode(payload: "", format: format) == nil)
        }
        // QR + Code128 are CoreImage's; exactly one encoder per symbology.
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "1234", format: .qr) == nil)
        #expect(OneDimensionalBarcodeEncoder.encode(payload: "1234", format: .code128) == nil)
    }

    @Test func encodingIsDeterministic() throws {
        let first = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: ean13Fixture, format: .ean13))
        let second = try #require(
            OneDimensionalBarcodeEncoder.encode(payload: ean13Fixture, format: .ean13))
        #expect(first == second)
    }

    /// Quiet zones are all-light and the symbol starts/ends with a dark guard
    /// module directly inside them.
    private func expectGuards(_ matrix: BarcodeMatrix, quietLeft: Int, quietRight: Int) {
        for x in 0..<quietLeft {
            #expect(!matrix.isSet(x: x, y: 0), "left quiet zone module \(x) is dark")
        }
        for x in (matrix.width - quietRight)..<matrix.width {
            #expect(!matrix.isSet(x: x, y: 0), "right quiet zone module \(x) is dark")
        }
        #expect(matrix.isSet(x: quietLeft, y: 0), "symbol does not start with a dark guard")
        #expect(matrix.isSet(x: matrix.width - quietRight - 1, y: 0), "symbol does not end dark")
    }
}
