import CoreGraphics
import CoreImage
import Foundation

/// Encodes a `ScannableCard`'s `(payload, format)` into a symbol the renderer can draw.
/// Mirror of Android `passes-core`'s `BarcodeEncoder` (wpass-1kg): the single encode
/// entry point for the roster, so the storage layer's trial-encode gate and the render
/// layer judge encodability with the same code and can never diverge. Pure synchronous
/// function; callers that want the main thread free wrap the call themselves.
///
/// **Validation boundary.** Input is expected to have cleared `ScannableCardInputValidator`;
/// the per-symbology encoders still re-check structure defensively (see
/// `OneDimensionalBarcodeEncoder`) because a rendered code that scans to a different
/// payload would be worse than a failure tile.
///
/// **No-throw contract.** Outcomes surface via exhaustive `switch` on ``EncodeResult``,
/// never via `throws` — the sibling family to `ScannableCardCreateResult`, kept separate
/// so a render-time call site does not drag the create-flow arms in.
///
/// **One encoder per symbology.** EAN-13 / UPC-A / Code39 delegate to the hand-rolled
/// `OneDimensionalBarcodeEncoder`; QR and Code128 own the CoreImage generators here
/// (moved down from `PassesUI.BarcodeRenderer`, which now routes through this entry).
/// QR error correction is pinned at level M — `ScannableFormatConstraints`' byte-mode
/// ceiling was derived against that pin; changing one means re-deriving the other.
public enum BarcodeEncoder {

    public static func encode(payload: String, format: ScannableFormat) -> EncodeResult {
        if let refusal = refuseBeforeWriter(payload: payload, format: format) {
            return .failure(reason: refusal)
        }
        switch format {
        case .qr, .code128:
            guard let image = coreImageSymbol(payload: payload, format: format) else {
                // CoreImage reports refusal as a nil `outputImage`, never a reason. For QR
                // the only payload-caused nil is over-capacity at v40-M (the proactive
                // check below catches the multibyte case; this arm is the belt-and-
                // suspenders for anything that slips past it). Code128 nil means the
                // generator refused the bytes (non-ASCII reaches here only when the
                // upstream validator was bypassed).
                let reason: EncoderFailureReason =
                    format == .qr
                    ? .payloadTooDense
                    : .writerRejected(format: format, detail: Detail.generatorRefused)
                return .failure(reason: reason)
            }
            return .success(symbol: .image(image))
        case .ean13, .upcA, .code39:
            guard let matrix = OneDimensionalBarcodeEncoder.encode(payload: payload, format: format)
            else {
                return .failure(
                    reason: .writerRejected(format: format, detail: Detail.structuralRecheckFailed))
            }
            return .success(symbol: .matrix(matrix))
        }
    }

    /// The refusals decided without running a generator, or nil to proceed.
    ///
    /// An empty payload is refused uniformly for every format: the validator rejects it
    /// upstream, but the generators disagree with each other about it (CoreImage happily
    /// encodes an empty QR; the 1D trio returns nil), and one deliberate refusal beats
    /// five incidental behaviors.
    ///
    /// The QR check is the proactive ``EncoderFailureReason/payloadTooDense`` that closes
    /// the char-cap-vs-byte-capacity gap (see `ScannableFormatConstraints`' ceiling doc):
    /// it is gated on alphanumeric-mode membership because a payload that fits QR's
    /// numeric or alphanumeric mode has far more capacity than byte mode, and
    /// pre-rejecting those against the byte ceiling would over-reject.
    private static func refuseBeforeWriter(
        payload: String, format: ScannableFormat
    ) -> EncoderFailureReason? {
        if payload.isEmpty {
            return .writerRejected(format: format, detail: Detail.emptyPayload)
        }
        guard format == .qr else { return nil }
        let needsByteMode = payload.contains { !ScannableFormatConstraints.isQrAlphanumericChar($0) }
        if needsByteMode, payload.utf8.count > ScannableFormatConstraints.qrByteCeilingEccMByteMode {
            return .payloadTooDense
        }
        return nil
    }

    /// Runs the CoreImage generator for QR / Code128. The same construction
    /// `PassesUI.BarcodeRenderer` used before it delegated here — module-per-pixel
    /// output, QR correction level pinned at M.
    private static func coreImageSymbol(payload: String, format: ScannableFormat) -> CGImage? {
        let data = Data(payload.utf8)
        let filter: CIFilter?
        switch format {
        case .qr:
            filter = CIFilter(name: "CIQRCodeGenerator")
            filter?.setValue(data, forKey: "inputMessage")
            filter?.setValue("M", forKey: "inputCorrectionLevel")
        case .code128:
            filter = CIFilter(name: "CICode128BarcodeGenerator")
            filter?.setValue(data, forKey: "inputMessage")
        case .ean13, .upcA, .code39:
            return nil
        }
        guard let output = filter?.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Kernel-authored refusal wording. Unlike Android, no third-party message exists to
    /// carry: CoreImage yields no reason and the 1D encoder returns bare nil, so `detail`
    /// can never echo payload-derived text.
    private enum Detail {
        static let emptyPayload = "Empty payload"
        static let generatorRefused = "CoreImage generator refused the payload"
        static let structuralRecheckFailed = "1D structural re-check failed"
    }
}

/// Outcome of ``BarcodeEncoder/encode(payload:format:)``. Sibling family to
/// `ScannableCardCreateResult` — the storage layer folds a `failure` into
/// `ScannableCardCreateResult.encoderFailure` when it wraps validation + encoding into
/// one create flow.
public enum EncodeResult: Sendable {
    case success(symbol: EncodedBarcodeSymbol)
    case failure(reason: EncoderFailureReason)
}

/// What the encoder produced: the 1D trio yields a module matrix the renderer
/// rasterizes; the CoreImage formats yield the generator's module-per-pixel image
/// directly. `@unchecked Sendable` per the kernel policy: `CGImage` is an immutable,
/// documented-thread-safe object (its pixel data cannot change after creation), and
/// `BarcodeMatrix` is a value type.
public enum EncodedBarcodeSymbol: @unchecked Sendable {
    case matrix(BarcodeMatrix)
    case image(CGImage)
}
