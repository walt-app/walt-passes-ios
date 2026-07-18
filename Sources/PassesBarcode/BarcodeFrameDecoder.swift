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
/// ## Boundary type: `CVPixelBuffer`, not Android's `ByteArray` + geometry (ADR `barcode-decode-1`)
/// Android hands the kernel a raw Y-plane `ByteArray` plus `rowStride`/`pixelStride` because ZXing's
/// `PlanarYUVLuminanceSource` consumes exactly that, and the shape keeps the module KMP-clean. iOS
/// deviates: **Vision ingests a `CVPixelBuffer` natively** (including the camera's biplanar YUV
/// formats), so a `decodeYPlane`-shaped byte entry would force this module to *rebuild* a pixel
/// buffer from the bytes — touching CoreVideo anyway and discarding Vision's own plane handling.
/// `CVPixelBuffer` is **CoreVideo**, not AVFoundation/CoreMedia: the capture-pipeline glue
/// (`AVCaptureVideoDataOutput` → `CMSampleBuffer` → `CMSampleBufferGetImageBuffer`) stays entirely
/// app-side; the kernel receives a bare frame snapshot.
///
/// ## `orientation` is provided for correctness/parity, not required for the symbol to decode
/// `orientation` (an `ImageIO` `CGImagePropertyOrientation`) is the honest analogue of Android's
/// `reverseHorizontal` mirror flag and can express both mirroring and device rotation — the app
/// passes its true capture orientation. Unlike ZXing (whose 1D reader needs `reverseHorizontal`),
/// **`VNDetectBarcodesRequest` is largely orientation-invariant**: it internally tries rotations and
/// mirrorings, so a rotated or front-camera-mirrored roster symbol decodes even at `.up`. The
/// parameter is therefore carried for a correct request handler (it orients observation geometry)
/// and API parity, not because the payload decode depends on it.
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

/// `@unchecked Sendable` box carrying the `CVPixelBuffer` across the ``withDecodeTimeout`` detached
/// task boundary. A CoreVideo pixel buffer is an immutable frame snapshot the app has already handed
/// off — only the single detached decode task reads it, and Vision reads it once — so there is no
/// concurrent access to guard. The box is this type's ADR per the repo's `@unchecked Sendable`
/// policy (`decisions-and-learnings.md`): the boundary crossing is explicit and the safety argument
/// is documented at the site.
private struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
