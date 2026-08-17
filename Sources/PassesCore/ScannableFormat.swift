import Foundation

/// The barcode formats a `ScannableCard` may render. The roster covers the long tail of
/// physical-world cards real users actually hold:
///
///  - `code128` — most modern membership/loyalty cards (alphanumeric, variable length)
///  - `ean13` — European retail barcodes (13 numeric digits)
///  - `upcA` — North American retail barcodes (12 numeric digits)
///  - `code39` — older institutional cards (alphanumeric, fixed charset)
///  - `qr` — modern QR-based loyalty / event / payment cards
///  - `pdf417` — boarding passes, driver's licences, event tickets (stacked 2D)
///  - `aztec` — boarding passes (IATA BCBP) and transit tickets (square 2D)
///
/// `pdf417` and `aztec` were absent from v1 on the assumption that vendor-issued codes
/// arrive via PKPASS. wpass-pl7 disproved it: users import boarding passes as SCREENSHOTS,
/// which have no PKPASS to arrive in, so the code was unreachable at any input scale.
/// DataMatrix stays out deliberately — it widens the same surface (encoder, storage,
/// consumer format pickers) for no reported user need.
///
/// **Read/write asymmetry (transitional).** Every member here decodes today; `pdf417` and
/// `aztec` do NOT yet encode — the writer arms, with their error-correction and compaction
/// defaults, land with ios-pjs.16. Until then the validator refuses to mint a card in
/// either (`unsupportedFormat`) and the encoder refuses to encode one.
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
    /// Whether a user can create a `ScannableCard` in this format — which is to say whether
    /// this build can render one. False only for the decode-only members (`pdf417` /
    /// `aztec` until ios-pjs.16 wires their writers).
    ///
    /// **Consumers building a format picker must filter on this.** The picker cannot be
    /// derived from `allCases` alone: `ScannableCardInputValidator` refuses a non-creatable
    /// format with `unsupportedFormat`, so an unfiltered picker offers a choice whose Save
    /// fails on every tap. Exposed rather than left implicit because nothing about adding a
    /// decode-only member breaks a consumer's build — the failure is silent by construction.
    ///
    /// Backed by the same set the validator and encoder read, so the three cannot disagree.
    public func isCreatable() -> Bool {
        !ScannableFormatConstraints.decodeOnly.contains(self)
    }
}
