import Foundation

/// Single source of truth for per-symbology charset, length cap, required length, and
/// structural-checksum rules. Hook point for the wpass-lzi threat model — if a constraint
/// here changes, the threat-model doc must change alongside it.
///
/// Kept `internal` so the validator is the only callable boundary; the consumer never picks
/// "is this character allowed" off of this object directly. Bidi / control-character checks
/// live in the validator because they apply uniformly across all formats.
enum ScannableFormatConstraints {
    /// Soft cap on payload length per symbology. Numeric symbologies use their exact length.
    static func maxPayloadLength(_ format: ScannableFormat) -> Int {
        switch format {
        case .code128: return code128Max
        case .code39: return code39Max
        case .ean13: return ean13Length
        case .upcA: return upcALength
        case .qr: return qrMax
        }
    }

    /// Non-null only for fixed-length numeric symbologies (EAN-13, UPC-A).
    static func requiredLength(_ format: ScannableFormat) -> Int? {
        switch format {
        case .ean13: return ean13Length
        case .upcA: return upcALength
        default: return nil
        }
    }

    /// True if `char` is in the symbology's allowed charset. Bidi / control characters are
    /// rejected by the validator before this is consulted, so the per-format set need only
    /// describe the visible alphabet.
    static func isAllowedChar(format: ScannableFormat, char: Character) -> Bool {
        switch format {
        // Code128 subsets A/B/C between them cover printable ASCII; bytes outside that
        // range are rejected here (the upstream control-char check catches NUL etc first,
        // so this guard only fires on extended-Unicode input like "é").
        case .code128:
            guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
            return (printableAsciiMin...printableAsciiMax).contains(Int(scalar.value))
        case .code39:
            return code39Allowed.contains(char)
        case .ean13, .upcA:
            return ("0"..."9").contains(char)
        case .qr:
            return true
        }
    }

    /// Structural validation for fixed-length symbologies. Returns the rejection arm to surface
    /// (length mismatch wins over check-digit mismatch), or nil when the payload structurally
    /// conforms.
    static func validateStructural(format: ScannableFormat, payload: String) -> PayloadRejection? {
        switch format {
        case .ean13: return validateEan13(payload)
        case .upcA: return validateUpcA(payload)
        case .code128, .code39, .qr: return nil
        }
    }

    // Length already enforced by the validator via `requiredLength`; structural check assumes
    // a correctly-sized payload and only verifies the check digit.
    private static func validateEan13(_ payload: String) -> PayloadRejection? {
        // EAN-13: rightmost digit is the check digit. Weights from right (excluding check
        // digit) alternate 3, 1, 3, 1 ...; sum mod 10, then (10 - sum mod 10) mod 10.
        let digits = payload.compactMap { $0.wholeNumberValue }
        guard digits.count == payload.count, let last = digits.last else { return nil }
        let expected = ean13CheckDigit(Array(digits.dropLast()))
        return expected == last ? nil : .invalidCheckDigit(format: .ean13)
    }

    private static func validateUpcA(_ payload: String) -> PayloadRejection? {
        // UPC-A: weights from left (excluding check digit) alternate 3, 1, 3, 1 ...; equivalent
        // to EAN-13 with a leading implicit zero, but expressed directly here for clarity.
        let digits = payload.compactMap { $0.wholeNumberValue }
        guard digits.count == payload.count, let last = digits.last else { return nil }
        let expected = upcACheckDigit(Array(digits.dropLast()))
        return expected == last ? nil : .invalidCheckDigit(format: .upcA)
    }

    private static func ean13CheckDigit(_ twelveDigits: [Int]) -> Int {
        var sum = 0
        // Index from the right: position 0 = weight 3, position 1 = weight 1, alternating.
        for (indexFromRight, digit) in twelveDigits.reversed().enumerated() {
            sum += digit * (indexFromRight % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    private static func upcACheckDigit(_ elevenDigits: [Int]) -> Int {
        var sum = 0
        for (indexFromLeft, digit) in elevenDigits.enumerated() {
            sum += digit * (indexFromLeft % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// UTF-8 byte ceiling for a **byte-mode** QR payload at the encoder's pinned ECC level
    /// (M) and the largest QR version (40). Sourced from the QR spec's capacity tables.
    /// Used by the encoder for a proactive PayloadTooDense check that does not depend on
    /// matching the underlying encoder's English exception text. ECC-M was chosen at the
    /// encoder; if that pin changes, this constant must change in lockstep.
    ///
    /// **Mode-scoped.** QR's numeric and alphanumeric modes have larger ceilings (~5,596
    /// digits, ~3,391 alphanumeric chars at v40-M). The encoder gates this byte-mode
    /// ceiling behind a charset check (`isQrAlphanumericChar`); payloads that fit a denser
    /// mode bypass the proactive check and fall through to the encoder's mode selection.
    static let qrByteCeilingEccMByteMode: Int = 2_331

    /// QR alphanumeric mode's character set (per ISO/IEC 18004): digits, uppercase A-Z, and
    /// the punctuation set `$ % * + - . / :` plus space. A payload composed entirely of
    /// these characters can be encoded in alphanumeric (or numeric, for all-digit input)
    /// mode, where capacity is much larger than byte mode. The encoder uses this membership
    /// test to decide whether the byte-mode pre-check is even applicable.
    static func isQrAlphanumericChar(_ char: Character) -> Bool {
        qrAlphanumeric.contains(char)
    }

    private static let qrAlphanumeric: Set<Character> = {
        var set: Set<Character> = []
        for c in "0123456789" { set.insert(c) }
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { set.insert(c) }
        for c in [" ", "$", "%", "*", "+", "-", ".", "/", ":"] as [Character] { set.insert(c) }
        return set
    }()

    private static let code128Max = 80
    private static let code39Max = 80
    private static let ean13Length = 13
    private static let upcALength = 12
    private static let qrMax = 2000
    private static let printableAsciiMin = 0x20
    private static let printableAsciiMax = 0x7E

    private static let code39Allowed: Set<Character> = {
        var set: Set<Character> = []
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { set.insert(c) }
        for c in "0123456789" { set.insert(c) }
        for c in [" ", "-", ".", "$", "/", "+", "%"] as [Character] { set.insert(c) }
        return set
    }()
}
