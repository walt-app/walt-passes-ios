import PassesCore
import Vision

/// The symbology ALLOWLIST that clamps the iOS decoder to the two formats Phase 1 requires:
/// **QR + Code128** (ADR `barcode-decode-1`). Restricting `VNDetectBarcodesRequest.symbologies`
/// to this pair narrows both the work Vision does and the parser surface a hostile image can
/// reach — the iOS analogue of Android's `POSSIBLE_FORMATS` hint pin.
///
/// ## Deviation from Android (accepted, ADR `barcode-decode-1`)
/// Android's roster is the full ``ScannableFormat`` set (Code128/EAN-13/UPC-A/Code39/QR) because
/// its ZXing reader decodes them all. iOS Phase 1 clamps to QR + Code128 only — the two
/// symbologies the app actually renders and imports in Phase 1. The other ``ScannableFormat``
/// cases stay in the model type (they describe what a `ScannableCard` may *render*) but are not
/// *decodable* on iOS yet; enabling EAN-13 / UPC-A / Code39 decode is a separate, re-escalatable
/// §7 decision, not a default.
enum RosterSymbology {
    /// The exact symbologies handed to `VNDetectBarcodesRequest`. Nothing outside this pair is
    /// ever requested, so Vision cannot return an out-of-roster symbol.
    static let requested: [VNBarcodeSymbology] = [.qr, .code128]

    /// Map a Vision symbology to the ``ScannableFormat`` Walt renders, or `nil` for anything
    /// outside the clamp. Because ``requested`` pins the request, `nil` is unreachable in
    /// practice — the decoder treats it as a defensive `unsupportedBarcodeFormat` failure so a
    /// later roster change can't silently force an unsupported symbol into an ill-fitting result.
    static func scannableFormat(for symbology: VNBarcodeSymbology) -> ScannableFormat? {
        switch symbology {
        case .qr: return .qr
        case .code128: return .code128
        default: return nil
        }
    }
}
