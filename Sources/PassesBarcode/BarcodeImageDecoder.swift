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
///  2. ``VisionSymbolDecode/detectBarcode(using:)`` — the roster-pinned `VNDetectBarcodesRequest`,
///     shared verbatim with the live-frame path — reads the symbol in Vision's system services, out
///     of Walt's address space (the iOS analogue of Android's isolated decode process).
///  3. BOTH steps — the ImageIO decode and the Vision read — run under
///     ``withDecodeTimeout(_:on:timeoutValue:operation:)`` — the app-level `ProcessKiller`
///     analogue — so a hung codec or symbol decode reports `decodeTimedOut` rather than blocking
///     the caller. They run on the untrusted-input bank (``DecodeBank/stillImage``), which cannot
///     consume capacity the live camera path needs. (The shared primitive decodes eagerly, so the
///     codec work must sit inside the wait — a lazy image would defer it to first Vision use, but
///     relying on laziness left the codec's placement implicit and once escaped the lane
///     entirely.) The one check outside the wait is the I/O-free `.data` byte cap, so an over-cap
///     buffer rejects with its real arm even when every lane is busy.
///
/// The payload is returned FAITHFULLY: nothing here interprets, normalizes, or acts on the decoded
/// bytes. `Sendable` via immutable `config`; no shared mutable state, so no lock is needed.
public struct VisionBarcodeImageDecoder: BarcodeImageDecoder {
    private let config: BarcodeDecodeConfig
    /// Seam so tests can observe the executor the ImageIO step runs on (mirror of
    /// Android's `doDecode` boundedDecode parameter); production always uses the
    /// real bounded decode.
    private let boundedDecode: @Sendable (BarcodeImageSource, BarcodeDecodeConfig) -> BoundedImageDecode.Outcome

    public init(config: BarcodeDecodeConfig = BarcodeDecodeConfig()) {
        self.init(config: config, boundedDecode: { BoundedImageDecode.decode($0, config: $1) })
    }

    init(
        config: BarcodeDecodeConfig,
        boundedDecode: @escaping @Sendable (BarcodeImageSource, BarcodeDecodeConfig) -> BoundedImageDecode.Outcome
    ) {
        self.config = config
        self.boundedDecode = boundedDecode
    }

    public func decode(source: BarcodeImageSource) async -> BarcodeDecodeResult {
        if case .data(let bytes) = source, bytes.count > config.maxBytes {
            return .decodeFailed(reason: .imageTooLarge)
        }
        let config = self.config
        let boundedDecode = self.boundedDecode
        return await withDecodeTimeout(
            config.decodeTimeout,
            on: .stillImage,
            timeoutValue: .decodeFailed(reason: .decodeTimedOut)
        ) {
            switch boundedDecode(source, config) {
            case .rejected(let reason):
                return .decodeFailed(reason: reason)
            case .decoded(let cgImage):
                return VisionSymbolDecode.detectBarcode(
                    using: VNImageRequestHandler(cgImage: cgImage, options: [:]))
            }
        }
    }
}
