import Foundation

/// Kernel-native encoder for the 1D symbologies CoreImage ships no generator
/// for: EAN-13, UPC-A, and Code 39 (ADR `passes-ui-2`, revised 2026-07-27).
/// QR and Code128 stay on the CoreImage path in `PassesUI.BarcodeRenderer`;
/// this encoder deliberately returns `nil` for them so there is exactly one
/// encoder per symbology.
///
/// Output is a single-row ``BarcodeMatrix`` (one module per column, quiet
/// zones included) that the renderer stretches vertically — 1D symbols carry
/// no vertical information. Patterns are implemented from the GS1 / AIM
/// specs with the same shape ZXing renders on Android (Code 39 wide:narrow
/// ratio 2:1), and every table is structurally self-checked by
/// `OneDimensionalBarcodeEncoderTests` plus a Vision decode round-trip.
///
/// **Validation boundary.** Mirrors Android `BarcodeEncoder`: input is
/// expected to have cleared `ScannableCardInputValidator`, but the encoder
/// still re-checks structure defensively (charset, exact length, check
/// digit) and returns `nil` rather than encoding garbage — a rendered code
/// that scans to a different payload would be worse than a failure tile.
public enum OneDimensionalBarcodeEncoder {

    /// Encode `payload` for a 1D `format`. Returns `nil` for QR/Code128
    /// (CoreImage owns those), for payloads that fail the symbology's
    /// structural rules (charset, exact length, check digit — delegated to
    /// `ScannableFormatConstraints`, the single source of truth), and for
    /// empty input.
    public static func encode(payload: String, format: ScannableFormat) -> BarcodeMatrix? {
        switch format {
        case .ean13:
            guard structurallyValidDigits(payload, format: .ean13, length: 13) else { return nil }
            // GS1 quiet zones: 11 modules left, 7 right.
            return ean13Symbol(payload).map { matrix(quietPadded($0, left: 11, right: 7)) }
        case .upcA:
            // UPC-A is the leading-zero subset of EAN-13: same 95-module
            // symbol, narrower quiet zones (9 modules per side vs 11/7).
            guard structurallyValidDigits(payload, format: .upcA, length: 12) else { return nil }
            return ean13Symbol("0" + payload).map { matrix(quietPadded($0, left: 9, right: 9)) }
        case .code39:
            return code39Row(payload).map(matrix)
        case .qr, .code128, .pdf417, .aztec:
            return nil
        }
    }

    private static func structurallyValidDigits(
        _ payload: String, format: ScannableFormat, length: Int
    ) -> Bool {
        payload.count == length
            && payload.allSatisfy { ScannableFormatConstraints.isAllowedChar(format: format, char: $0) }
            && ScannableFormatConstraints.validateStructural(format: format, payload: payload) == nil
    }

    // MARK: - EAN-13

    /// 7-module L-codes per digit (left half, odd parity). R = complement,
    /// G = R reversed; both derived so the three tables cannot drift apart.
    private static let ean13LCodes: [[Bool]] = [
        "0001101", "0011001", "0010011", "0111101", "0100011",
        "0110001", "0101111", "0111011", "0110111", "0001011",
    ].map(bits)

    private static var ean13RCodes: [[Bool]] { ean13LCodes.map { $0.map { !$0 } } }
    private static var ean13GCodes: [[Bool]] { ean13RCodes.map { $0.reversed() } }

    /// First-digit parity pattern for the six left-half digits: `false` = L,
    /// `true` = G.
    private static let ean13Parity: [[Bool]] = [
        "000000", "001011", "001101", "001110", "010011",
        "011001", "011100", "010101", "010110", "011010",
    ].map(bits)

    /// The bare 95-module EAN-13 symbol for 13 already-validated digits.
    private static func ean13Symbol(_ payload: String) -> [Bool]? {
        let digits = payload.compactMap(\.wholeNumberValue)
        guard digits.count == 13 else { return nil }

        var row: [Bool] = bits("101")
        let parity = ean13Parity[digits[0]]
        for (index, digit) in digits[1...6].enumerated() {
            row += parity[index] ? ean13GCodes[digit] : ean13LCodes[digit]
        }
        row += bits("01010")
        for digit in digits[7...12] {
            row += ean13RCodes[digit]
        }
        row += bits("101")
        return row
    }

    // MARK: - Code 39

    /// 9-element encodings (5 bars, 4 spaces, alternating, bar first); a set
    /// bit means a WIDE element (2 modules), clear means narrow (1 module).
    /// MSB is the first element. Same table ZXing renders on Android.
    private static let code39Encodings: [Character: UInt16] = [
        "0": 0x034, "1": 0x121, "2": 0x061, "3": 0x160, "4": 0x031,
        "5": 0x130, "6": 0x070, "7": 0x025, "8": 0x124, "9": 0x064,
        "A": 0x109, "B": 0x049, "C": 0x148, "D": 0x019, "E": 0x118,
        "F": 0x058, "G": 0x00D, "H": 0x10C, "I": 0x04C, "J": 0x01C,
        "K": 0x103, "L": 0x043, "M": 0x142, "N": 0x013, "O": 0x112,
        "P": 0x052, "Q": 0x007, "R": 0x106, "S": 0x046, "T": 0x016,
        "U": 0x181, "V": 0x0C1, "W": 0x1C0, "X": 0x091, "Y": 0x190,
        "Z": 0x0D0, "-": 0x085, ".": 0x184, " ": 0x0C4, "$": 0x0A8,
        "/": 0x0A2, "+": 0x08A, "%": 0x02A,
    ]

    private static let code39StartStop: UInt16 = 0x094  // '*'

    /// Test seam: the full encoding table including start/stop, so the
    /// structural pins (exactly three wide elements per character) cover
    /// every entry.
    static var code39AllEncodings: [UInt16] {
        Array(code39Encodings.values) + [code39StartStop]
    }

    private static func code39Row(_ payload: String) -> [Bool]? {
        guard !payload.isEmpty else { return nil }
        var encodings: [UInt16] = [code39StartStop]
        for char in payload {
            guard let encoding = code39Encodings[char] else { return nil }
            encodings.append(encoding)
        }
        encodings.append(code39StartStop)

        var row: [Bool] = []
        for (index, encoding) in encodings.enumerated() {
            if index > 0 { row.append(false) }  // narrow inter-character gap
            for element in 0..<9 {
                let wide = encoding & (1 << (8 - element)) != 0
                let dark = element.isMultiple(of: 2)  // bars at even positions
                row += Array(repeating: dark, count: wide ? 2 : 1)
            }
        }
        return quietPadded(row, left: 10, right: 10)
    }

    // MARK: - Helpers

    private static func quietPadded(_ symbol: [Bool], left: Int, right: Int) -> [Bool] {
        Array(repeating: false, count: left) + symbol + Array(repeating: false, count: right)
    }

    private static func matrix(_ row: [Bool]) -> BarcodeMatrix {
        BarcodeMatrix(width: row.count, height: 1, modules: row)
    }

    private static func bits(_ pattern: String) -> [Bool] {
        pattern.map { $0 == "1" }
    }
}
