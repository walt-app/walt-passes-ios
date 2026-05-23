import Foundation

/// The barcode formats a `ScannableCard` may render. The v1 roster covers the long tail of
/// physical-world cards real users actually hold:
///
///  - `code128` — most modern membership/loyalty cards (alphanumeric, variable length)
///  - `ean13` — European retail barcodes (13 numeric digits)
///  - `upcA` — North American retail barcodes (12 numeric digits)
///  - `code39` — older institutional cards (alphanumeric, fixed charset)
///  - `qr` — modern QR-based loyalty / event / payment cards
///
/// Pdf417 and Aztec are intentionally absent from v1: they are largely vendor-issued
/// (boarding passes, transit) and arrive via PKPASS already.
///
/// Distinct type from `BarcodeFormat` (the PKPASS-pass barcode enum). The two are
/// deliberately not unified — a verified PKPASS barcode and a user-typed card barcode are
/// different trust artifacts that happen to share a rendering technology. Casing also
/// differs (`qr` here vs `QR` there): this enum follows Swift's lowerCamelCase enum
/// convention; the PKPASS one predates the convention switch in this repo.
public enum ScannableFormat: Sendable, CaseIterable {
    case code128
    case ean13
    case upcA
    case code39
    case qr
}
