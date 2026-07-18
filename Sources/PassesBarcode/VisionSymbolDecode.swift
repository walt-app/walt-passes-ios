import PassesCore
import Vision

/// The ONE Vision symbol decode shared by the still-image and live-frame paths (mirror of Android
/// `decodeLuminance`). Both paths build a `VNImageRequestHandler` from their own pixel source — a
/// bounded `CGImage` for the still-image path (``VisionBarcodeImageDecoder``), a `CVPixelBuffer`
/// for the live camera frame (``VisionBarcodeFrameDecoder``) — and hand it here. The roster clamp
/// and result folding do **not** fork: one implementation, one allowlist (ADR `barcode-decode-1`).
///
/// The payload is returned FAITHFULLY: nothing here interprets, normalizes, or acts on the decoded
/// bytes. Classification/validation stay downstream in the consumer (`QrPayloadKind` /
/// `ScannableCardInputValidator`).
enum VisionSymbolDecode {
    /// Run the roster-pinned `VNDetectBarcodesRequest` on `handler` and fold the observations onto a
    /// ``BarcodeDecodeResult``: the first observation carrying a payload string wins (Android "first
    /// barcode found"); a symbology outside the clamp is the defensive
    /// ``DecodeFailureReason/unsupportedBarcodeFormat`` guard (unreachable while the request is
    /// pinned); a Vision `perform` failure is ``DecodeFailureReason/decoderUnavailable``.
    static func detectBarcode(using handler: VNImageRequestHandler) -> BarcodeDecodeResult {
        let request = VNDetectBarcodesRequest()
        request.symbologies = RosterSymbology.requested
        do {
            try handler.perform([request])
        } catch {
            return .decodeFailed(reason: .decoderUnavailable)
        }
        guard let observation = request.results?.first(where: { $0.payloadStringValue != nil }) else {
            return .noBarcodeFound
        }
        guard let format = RosterSymbology.scannableFormat(for: observation.symbology) else {
            return .decodeFailed(reason: .unsupportedBarcodeFormat)
        }
        // Force-unwrap is safe: the `first(where:)` predicate already required a non-nil payload.
        return .decodedBarcode(payload: observation.payloadStringValue!, format: format)
    }
}
