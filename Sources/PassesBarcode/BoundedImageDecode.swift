import CoreGraphics
import Foundation
import ImageIO
import PassesCore
import PassesImageDecode
import UniformTypeIdentifiers

/// The bounded still-image decode (mirror of Android's `BoundedBitmapDecoder` +
/// `decodeBoundedFromPfd`). Turns a ``BarcodeImageSource`` into a `CGImage` while enforcing every
/// ``BarcodeDecodeConfig`` cap *before* a full-size bitmap is allocated, so a decompression bomb is
/// refused at the header rather than after the allocation that would OOM the process.
///
/// The order matters and mirrors Android's header-listener discipline:
///  1. Bound the compressed byte count first (``BarcodeDecodeConfig/maxBytes``) — cheapest gate.
///  2. Open a `CGImageSource` *without* decoding pixels.
///  3. Reject containers outside ``BarcodeDecodeConfig/allowedContentTypes`` at the header step.
///  4. Read the advertised pixel dimensions from the header and reject over-dimension /
///     over-megapixel images — the decompression-bomb guard — before any bitmap is allocated.
///  5. Only then materialize the `CGImage`.
///
/// Every failure folds onto a bucketed ``DecodeFailureReason``; nothing throws and nothing is
/// logged (no payload, bytes, or dimensions leak out).
enum BoundedImageDecode {
    enum Outcome {
        case decoded(CGImage)
        case rejected(DecodeFailureReason)
    }

    static func decode(_ source: BarcodeImageSource, config: BarcodeDecodeConfig) -> Outcome {
        guard let data = boundedBytes(source, maxBytes: config.maxBytes) else {
            return .rejected(mapReadFailure(source))
        }
        // Distinguish "too large" from "unreadable": a source that read fully but exceeds the byte
        // cap is the bomb shape, not an I/O error.
        if data.count > config.maxBytes {
            return .rejected(.imageTooLarge)
        }
        // The header-gated steps delegate to the shared `PassesImageDecode` primitive
        // (wpass-gnp mirror, ios-dts.2); this lane keeps its own POLICY — the barcode
        // allowlist and caps, folded onto `DecodeFailureReason` — while the mechanism
        // (container judged before the metadata read, dimensions before any
        // allocation, gate wins, malformed folds) is shared with the image-document
        // lane. Check order is unchanged from the pre-delegation code.
        let policy = BoundedDecodePolicy<DecodeFailureReason>(
            containerGate: { type in
                guard let type, config.allowedContentTypes.contains(where: { type.conforms(to: $0) })
                else { return .imageDecodeFailed }
                return nil
            },
            dimensionGate: { width, height in
                exceedsCaps(width: width, height: height, config: config) ? .imageTooLarge : nil
            },
            onMalformed: { .imageDecodeFailed },
            onDecodeFailed: { .imageDecodeFailed }
        )
        switch decodeBounded(rawBytes: data, policy: policy) {
        // The read lane decodes to scan, never to retain or persist dimensions,
        // so the header orientation is deliberately unused (Vision is
        // rotation-tolerant across the roster).
        case .decoded(let cgImage, _): return .decoded(cgImage)
        case .rejected(let reason): return .rejected(reason)
        }
    }

    /// Read the source's compressed bytes, reading at most `maxBytes + 1` so an oversize source is
    /// detected without pulling the whole bomb into memory. Returns `nil` only when the source
    /// could not be read at all (distinct from "read, but over the cap").
    private static func boundedBytes(_ source: BarcodeImageSource, maxBytes: Int) -> Data? {
        switch source {
        case .data(let data):
            // Already resident; cap is enforced by the caller comparing count.
            return data
        case .fileURL(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            // Read one byte past the cap so an over-cap file is flagged rather than truncated
            // into a decodable prefix.
            return try? handle.read(upToCount: maxBytes + 1)
        }
    }

    /// True when the header's advertised dimensions exceed the per-side or megapixel cap — the
    /// decompression-bomb guard, checked before any bitmap is allocated.
    private static func exceedsCaps(width: Int, height: Int, config: BarcodeDecodeConfig) -> Bool {
        width > config.maxDimensionPx
            || height > config.maxDimensionPx
            || width * height > config.maxAreaPx
    }

    /// The read failed outright: a `.data` source can't fail to read, so any read failure is a
    /// `.fileURL` the OS could not open.
    private static func mapReadFailure(_ source: BarcodeImageSource) -> DecodeFailureReason {
        switch source {
        case .data: return .imageDecodeFailed
        case .fileURL: return .sourceUnreadable
        }
    }
}
