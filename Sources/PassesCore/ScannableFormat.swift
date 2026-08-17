import Foundation

/// The barcode formats a `ScannableCard` may render. The roster covers the long tail of
/// physical-world cards real users actually hold:
///
///  - `code128` — most modern membership/loyalty cards (alphanumeric, variable length)
///  - `ean13` — European retail barcodes (13 numeric digits)
///  - `upcA` — North American retail barcodes (12 numeric digits)
///  - `code39` — older institutional cards (alphanumeric, fixed charset)
///  - `qr` — modern QR-based loyalty / event / payment cards
///  - `pdf417` — boarding passes and event tickets (stacked 2D)
///  - `aztec` — boarding passes (IATA BCBP) and transit tickets (square 2D)
///
/// `pdf417` and `aztec` joined with ios-pjs.15 (users import boarding passes as
/// screenshots, which have no PKPASS to arrive in); ios-pjs.16 wired their writers, with
/// a Latin-1 payload charset (§7-approved — the CoreImage generators cannot declare a
/// charset, so ISO-8859-1, the ECI-less spec default, is the one encoding every reader
/// agrees on). DataMatrix stays out deliberately. Full record: ADR `barcode-decode-1`.
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
    case pdf417
    case aztec
}

extension ScannableFormat {
    /// Whether a user can create a `ScannableCard` in this format — i.e. whether this
    /// build can render one. **Consumers building a format picker must filter on this**;
    /// an unfiltered picker offers a choice whose Save fails on every tap, and nothing
    /// about a decode-only member breaks a consumer's build. Backed by the same set the
    /// validator and encoder read, so the three cannot disagree.
    public func isCreatable() -> Bool {
        !ScannableFormatConstraints.decodeOnly.contains(self)
    }

    /// Whether a symbol in this format can carry a payload a scanner may ACT on (URIs:
    /// links, dialers, wallets). The C4 confirm-before-create gate keys off this
    /// (ios-pjs.17, wlt-9o3x analogue): QR, PDF417 and Aztec are byte-capable and carry
    /// the same actionable schemes; the 1D trio cannot express them in practice and no
    /// scanner auto-acts on 1D content. Exhaustive here so a roster addition is a
    /// compile-time decision at one kernel site, not a gate that quietly stops covering
    /// a format.
    public func canCarryActionablePayload() -> Bool {
        switch self {
        case .qr, .pdf417, .aztec: return true
        case .code128, .code39, .ean13, .upcA: return false
        }
    }
}
