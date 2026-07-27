import PassesCore
import Vision

/// The symbology ALLOWLIST that clamps the iOS decoder to the full ``ScannableFormat`` roster
/// (ADR `barcode-decode-1`, revised 2026-07-27 — the re-escalatable "Android symbol parity"
/// decision was taken, human-approved: QR / Code128 / EAN-13 / UPC-A / Code39, matching
/// Android's ZXing `POSSIBLE_FORMATS` pin). Restricting `VNDetectBarcodesRequest.symbologies`
/// still narrows both the work Vision does and the parser surface a hostile image can reach.
///
/// UPC-A has no `VNBarcodeSymbology` of its own: Vision reports it as EAN-13 with a leading
/// zero. ``fold(symbology:payload:)`` reverses that (leading-zero EAN-13 → `.upcA`, 12-digit
/// payload), mirroring ZXing, whose UPC-A reader wins over EAN-13 for leading-zero codes and
/// returns the 12-digit form.
enum RosterSymbology {
    /// The exact symbologies handed to `VNDetectBarcodesRequest`. Nothing outside this set is
    /// ever requested, so Vision cannot return an out-of-roster symbol.
    static let requested: [VNBarcodeSymbology] = [.qr, .code128, .ean13, .code39]

    /// Fold a Vision observation onto the ``ScannableFormat`` Walt renders (plus the payload,
    /// which the UPC-A arm rewrites). `nil` for anything outside the clamp — unreachable while
    /// ``requested`` pins the request; the decoder treats it as a defensive
    /// `unsupportedBarcodeFormat` failure so a later roster change can't silently force an
    /// unsupported symbol into an ill-fitting result.
    static func fold(
        symbology: VNBarcodeSymbology, payload: String
    ) -> (format: ScannableFormat, payload: String)? {
        switch symbology {
        case .qr: return (.qr, payload)
        case .code128: return (.code128, payload)
        case .code39: return (.code39, payload)
        case .ean13:
            // A leading-zero EAN-13 IS a UPC-A code (GS1); report it the way
            // Android's ZXing does so cross-platform scans of the same card
            // classify identically.
            if payload.count == 13, payload.hasPrefix("0") {
                return (.upcA, String(payload.dropFirst()))
            }
            return (.ean13, payload)
        default: return nil
        }
    }
}
