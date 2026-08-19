import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one shared header-gated bounded decode (mirror of Android
/// `passes-image-decode`'s `decodeBounded`, wpass-gnp): mechanism only, generic over
/// the caller's rejection type `R`. Caps, container allowlists and the rejection
/// taxonomy are POLICY and stay with each consumer; this module names none of its
/// own and has no dependencies, sitting below the `PassesBarcode` / `PassesImage`
/// peers without adding an edge between them. Rationale and the Android containment
/// delta: `docs/adr/image-decode-1.md`.
///
/// The container gate runs BEFORE the header-properties read, so ImageIO's metadata
/// parser (its own CVE surface) never runs over a container the allowlist is about
/// to reject — stronger than Android's single header callback, which hands MIME and
/// size together (recorded in the ADR). The dimension gate then runs before any
/// pixel materialization; iOS needs no Android 1x1-target trick because not calling
/// `CGImageSourceCreateImageAtIndex` allocates nothing.
package struct BoundedDecodePolicy<R> {
    /// Judged from the codec's own container identification (nil when it cannot
    /// even identify one), before ANY metadata or pixel work.
    package let containerGate: (_ type: UTType?) -> R?
    /// Judged from the header's advertised dimensions, before any pixel allocation.
    package let dimensionGate: (_ width: Int, _ height: Int) -> R?
    /// Fold for bytes the codec cannot open and headers with no usable dimensions.
    package let onMalformed: () -> R
    /// Fold for a gate-cleared image that fails to materialize (truncated or
    /// corrupt body behind a valid header). Android splits these the same way
    /// (`onMalformed` vs `onRuntimeFailure`).
    package let onDecodeFailed: () -> R

    package init(
        containerGate: @escaping (_ type: UTType?) -> R?,
        dimensionGate: @escaping (_ width: Int, _ height: Int) -> R?,
        onMalformed: @escaping () -> R,
        onDecodeFailed: @escaping () -> R
    ) {
        self.containerGate = containerGate
        self.dimensionGate = dimensionGate
        self.onMalformed = onMalformed
        self.onDecodeFailed = onDecodeFailed
    }
}

package enum BoundedDecodeOutcome<R> {
    /// The decoded bitmap. A `CGImage` is immutable; handing it across concurrency
    /// seams is the consumer's concern.
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
    if let rejection = policy.containerGate(containerType) {
        return .rejected(rejection)
    }
    guard let (width, height) = headerDimensions(source) else {
        return .rejected(policy.onMalformed())
    }
    if let rejection = policy.dimensionGate(width, height) {
        return .rejected(rejection)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return .rejected(policy.onDecodeFailed())
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

/// The header's EXIF orientation (1...8; 1 when absent or unreadable), read without
/// decoding pixels. Consumers that fit or persist dimensions must apply it —
/// `CGImageSourceCreateImageAtIndex` returns STORED pixels (Android's `ImageDecoder`
/// applies orientation itself; ImageIO does not).
package func headerOrientation(rawBytes: Data) -> Int {
    guard
        let source = CGImageSourceCreateWithData(rawBytes as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
        (1...8).contains(orientation)
    else {
        return 1
    }
    return Int(orientation)
}

/// Saturating `Duration` → `DispatchTimeInterval`, shared by the consumers' bounded
/// waits: an absurd budget saturates rather than trapping (the overflow hardening
/// `PassesBarcode`'s copy carries; duplicating it re-introduced the trap once —
/// K2 review round 1).
package func saturatingDispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    if overflowed {
        return .nanoseconds(Int.max)
    }
    let (nanos, addOverflowed) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
    if addOverflowed {
        return .nanoseconds(Int.max)
    }
    return .nanoseconds(Int(clamping: nanos))
}
