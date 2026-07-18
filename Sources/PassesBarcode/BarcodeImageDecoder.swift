import CoreGraphics
import Foundation
import PassesCore
import Vision

/// The single consumer-facing entry point for decoding a barcode/QR from a user-supplied static
/// image (mirror of Android `BarcodeImageDecoder`). It owns the trust-claim-bearing orchestration
/// the consumer (walt-ios, A6 seam) would otherwise reassemble: bound the image decode, run the
/// symbol decode in Apple **Vision**, clamp the result to the QR + Code128 roster, and return only
/// `{payload, format}`.
///
/// Routing every decode through this seam is what keeps the hostile-input boundary honest — it
/// lives here, not parallel-implemented in the app. The facade returns no `CGImage` and no source
/// bytes, and does **not** classify or validate the payload: the consumer routes the returned
/// payload through the app's `QrPayloadKind` / `ScannableCardInputValidator`. That split is the
/// anti-spoof posture — a decoded payload never silently populates a user-facing label.
public protocol BarcodeImageDecoder: Sendable {
    /// Decode the first barcode found in `source`. Returns ``BarcodeDecodeResult/decodedBarcode(payload:format:)``
    /// on success, ``BarcodeDecodeResult/noBarcodeFound`` when the image decoded but held no
    /// recognizable roster symbol, or ``BarcodeDecodeResult/decodeFailed(reason:)`` folded onto a
    /// ``DecodeFailureReason`` at the first failing step.
    func decode(source: BarcodeImageSource) async -> BarcodeDecodeResult
}

/// The production ``BarcodeImageDecoder``, backed by Apple **Vision** (ADR `barcode-decode-1`).
///
/// One decode composes three steps:
///  1. ``BoundedImageDecode`` caps compressed size, container format, and canvas dimensions before
///     `CGImageSource` allocates a bitmap (decompression-bomb guard).
///  2. `VNDetectBarcodesRequest`, its `symbologies` pinned to the ``RosterSymbology/requested``
///     QR + Code128 clamp, reads the symbol — running in Vision's system services, out of Walt's
///     address space (the iOS analogue of Android's isolated decode process).
///  3. The whole Vision step runs under ``withDecodeTimeout(_:timeoutValue:operation:)`` — the
///     app-level `ProcessKiller` analogue — so a hung decode reports `decoderUnavailable` rather
///     than blocking the caller.
///
/// The payload is returned FAITHFULLY: nothing here interprets, normalizes, or acts on the decoded
/// bytes. `Sendable` via immutable `config`; no shared mutable state, so no lock is needed.
public struct VisionBarcodeImageDecoder: BarcodeImageDecoder {
    private let config: BarcodeDecodeConfig

    public init(config: BarcodeDecodeConfig = BarcodeDecodeConfig()) {
        self.config = config
    }

    public func decode(source: BarcodeImageSource) async -> BarcodeDecodeResult {
        switch BoundedImageDecode.decode(source, config: config) {
        case .rejected(let reason):
            return .decodeFailed(reason: reason)
        case .decoded(let cgImage):
            return await withDecodeTimeout(
                config.decodeTimeout,
                timeoutValue: .decodeFailed(reason: .decoderUnavailable)
            ) {
                Self.detectBarcode(in: cgImage)
            }
        }
    }

    /// The synchronous Vision decode. Runs the roster-pinned request and folds the observations
    /// onto a ``BarcodeDecodeResult``: the first observation carrying a payload string wins (Android
    /// "first barcode found"); a symbology outside the clamp is the defensive
    /// ``DecodeFailureReason/unsupportedBarcodeFormat`` guard (unreachable while the request is
    /// pinned); a Vision `perform` failure is ``DecodeFailureReason/decoderUnavailable``.
    private static func detectBarcode(in cgImage: CGImage) -> BarcodeDecodeResult {
        let request = VNDetectBarcodesRequest()
        request.symbologies = RosterSymbology.requested
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
