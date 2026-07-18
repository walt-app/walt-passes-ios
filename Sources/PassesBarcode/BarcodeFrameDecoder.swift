import CoreVideo
import Foundation
import ImageIO
import PassesCore
import Vision

/// The consumer-facing entry point for decoding a barcode/QR straight off a **live camera frame**
/// (mirror of Android `decodeYPlane`). Feeds the app's per-frame scan loop (A8): the app pulls a
/// `CVPixelBuffer` off its capture output and hands it here; the module returns the same
/// ``BarcodeDecodeResult`` contract as the still-image facade, clamped to the same QR + Code128
/// roster. ONE decode implementation, ONE roster — the live path does not fork (ADR
/// `barcode-decode-1`).
///
/// The kernel boundary is a `CVPixelBuffer` (CoreVideo), not Android's Y-plane `ByteArray` +
/// geometry: Vision ingests pixel buffers natively, and the capture glue (`CMSampleBuffer` etc.)
/// stays app-side. `orientation` (`CGImagePropertyOrientation`) is Android's `reverseHorizontal`
/// analogue but is **not** load-bearing — `VNDetectBarcodesRequest` is orientation-invariant, so it
/// is carried for a correct handler and parity only. Full rationale: ADR `barcode-decode-1`,
/// Deviation 4.
///
/// The payload is returned FAITHFULLY: nothing here interprets, classifies, or validates the bytes
/// (that stays downstream in the consumer's `QrPayloadKind` / `ScannableCardInputValidator`).
public protocol BarcodeFrameDecoder: Sendable {
    /// Decode the first roster barcode found in `frame`, interpreting the pixels under
    /// `orientation`. Returns ``BarcodeDecodeResult/decodedBarcode(payload:format:)`` on success,
    /// ``BarcodeDecodeResult/noBarcodeFound`` when the frame carried no recognizable roster symbol,
    /// or ``BarcodeDecodeResult/decodeFailed(reason:)`` (``DecodeFailureReason/decoderUnavailable``)
    /// when Vision failed or the decode overran its budget.
    func decode(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation) async -> BarcodeDecodeResult
}

extension BarcodeFrameDecoder {
    /// Convenience for the un-rotated case (`.up`), the shape most callers building a fixed-portrait
    /// scanner want; the mirrored/rotated cases pass `orientation` explicitly.
    public func decode(frame: CVPixelBuffer) async -> BarcodeDecodeResult {
        await decode(frame: frame, orientation: .up)
    }
}

/// The production ``BarcodeFrameDecoder``, backed by Apple **Vision** (ADR `barcode-decode-1`).
///
/// Unlike the still-image path there is no ``BoundedImageDecode`` step: a camera frame is
/// already-decoded pixels the app produced from its own capture session, not an untrusted file, so
/// the container-format / compressed-byte / decompression-bomb gates have nothing to bound (the app
/// owns the capture resolution). The two protections that DO carry over are the roster clamp and the
/// faithful-payload posture — both live in the shared ``VisionSymbolDecode/detectBarcode(using:)``
/// core — plus the ``withDecodeTimeout(_:timeoutValue:operation:)`` wait bound (the `ProcessKiller`
/// analogue) so a hung per-frame decode never stalls the scan loop.
///
/// `Sendable` via the immutable `decodeTimeout`; no shared mutable state, so no lock is needed.
public struct VisionBarcodeFrameDecoder: BarcodeFrameDecoder {
    private let decodeTimeout: Duration

    public init(decodeTimeout: Duration = BarcodeDecodeConfig.defaultDecodeTimeout) {
        self.decodeTimeout = decodeTimeout
    }

    public func decode(
        frame: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) async -> BarcodeDecodeResult {
        let frame = FrameBox(buffer: frame)
        return await withDecodeTimeout(
            decodeTimeout,
            timeoutValue: .decodeFailed(reason: .decoderUnavailable)
        ) {
            let handler = VNImageRequestHandler(
                cvPixelBuffer: frame.buffer,
                orientation: orientation,
                options: [:]
            )
            return VisionSymbolDecode.detectBarcode(using: handler)
        }
    }
}

/// `@unchecked Sendable` box handing the `CVPixelBuffer` to the ``withDecodeTimeout`` detached task:
/// a single reader over an immutable frame snapshot, no concurrent access (repo @unchecked policy).
private struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
