import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one shared header-gated bounded decode (mirror of Android
/// `passes-image-decode`'s `decodeBounded`, wpass-gnp): mechanism only, generic over
/// the caller's rejection type `R`. Caps, container allowlists and the rejection
/// taxonomy are POLICY and stay with each consumer — this module deliberately names
/// none of its own and has no dependencies, sitting below the `PassesBarcode` and
/// `PassesImage` peers without adding an edge between them.
///
/// Mechanism, in load-bearing order (the Android header-listener discipline):
///  1. Open a `CGImageSource` WITHOUT decoding pixels; unopenable bytes fold to
///     `onMalformed`.
///  2. Read the container type and the header's advertised dimensions — still no
///     pixel allocation.
///  3. Run the caller's gate over (type, width, height); a non-nil rejection wins
///     and the image is NEVER materialized (iOS needs no Android 1x1-target trick —
///     simply not calling `CGImageSourceCreateImageAtIndex` allocates nothing).
///  4. Only then materialize the `CGImage`; a materialization failure folds to
///     `onMalformed`.
///
/// Containment delta vs Android (recorded in the image-lane ADR): Android folds
/// `IOException` / `IllegalArgumentException` / `RuntimeException` and optionally
/// contains `OutOfMemoryError`; ImageIO reports failure by returning nil, and Swift
/// has no catchable allocation failure, so the fold surface here is exactly the two
/// nil-returns above. The gate's pre-allocation position is what bounds the
/// allocation, on both platforms.
package struct BoundedDecodePolicy<R> {
    /// Evaluated from the image HEADER, before any pixel allocation. `type` is what
    /// the codec says the container is (nil when it cannot even identify it — the
    /// gate decides what that means), never what the caller claimed.
    package let gate: (_ type: UTType?, _ width: Int, _ height: Int) -> R?
    /// Fold for bytes the codec cannot open, headers with no usable dimensions, and
    /// materialization failures.
    package let onMalformed: () -> R

    package init(
        gate: @escaping (_ type: UTType?, _ width: Int, _ height: Int) -> R?,
        onMalformed: @escaping () -> R
    ) {
        self.gate = gate
        self.onMalformed = onMalformed
    }
}

package enum BoundedDecodeOutcome<R> {
    /// The decoded bitmap. A `CGImage` is immutable, so handing it across the
    /// consumer's own concurrency seams is on the consumer.
    case decoded(CGImage)
    case rejected(R)
}

package func decodeBounded<R>(
    rawBytes: Data,
    policy: BoundedDecodePolicy<R>
) -> BoundedDecodeOutcome<R> {
    guard let source = CGImageSourceCreateWithData(rawBytes as CFData, nil) else {
        return .rejected(policy.onMalformed())
    }
    let containerType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
    guard let (width, height) = headerDimensions(source) else {
        return .rejected(policy.onMalformed())
    }
    if let rejection = policy.gate(containerType, width, height) {
        return .rejected(rejection)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return .rejected(policy.onMalformed())
    }
    return .decoded(image)
}

/// The advertised pixel dimensions from the image header, read without decoding
/// pixels.
private func headerDimensions(_ source: CGImageSource) -> (Int, Int)? {
    guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0
    else {
        return nil
    }
    return (width, height)
}
