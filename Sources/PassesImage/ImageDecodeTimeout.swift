import Foundation

/// Bounded WAIT for the image-document decode — the §7-priced translation of
/// Android's `DecodeWatchdog` (which kills its sandbox process; in-process iOS
/// cannot, so on expiry the caller is released with `timeoutValue` and the orphaned
/// work runs to completion on its lane, its result discarded). The header caps in
/// `BoundedRasterDecoder` are what keep the actual work bounded; this bounds how
/// long the caller waits. Same discipline as `PassesBarcode`'s `withDecodeTimeout`,
/// deliberately duplicated rather than shared: the image-document lane and the
/// barcode lanes must never share capacity, so a wedged import cannot starve the
/// camera (the ADR records the mapping).
///
/// Neither racer touches the Swift cooperative pool: decodes run on this module's
/// own serial lanes, deadlines on their own queue. A submission arriving with every
/// lane occupied is refused rather than queued, and the deadline reports it as a
/// timeout.
func withImageDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    lanes: ImageDecodeLanes = .shared,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        // Scheduled before the submission, not after: a refused submission runs
        // nothing, so the deadline is the only thing left that can resolve the
        // caller.
        ImageDecodeLanes.deadlines.asyncAfter(
            deadline: .now() + dispatchInterval(duration), execute: deadline.item)
        lanes.submit {
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
    }
}

/// Dedicated serial decode lanes this module owns — never the cooperative pool and
/// never a concurrent queue (which draws from the same thread pool the cooperative
/// pool exhausts). Occupancy is tracked so a full bank REFUSES a submission instead
/// of queueing it behind a possibly-wedged decode.
///
/// `@unchecked Sendable`: occupancy is mutable shared state guarded by an `NSLock`
/// (the doc comment is the ADR per the repo's policy); the queues themselves are
/// immutable.
final class ImageDecodeLanes: @unchecked Sendable {
    static let shared = ImageDecodeLanes(lanes: laneCount)
    static let deadlines = DispatchQueue(
        label: "is.walt.passes.image.decode-deadline", qos: .userInitiated)

    /// One import decodes at a time in practice; the extra lanes absorb a wedged
    /// decode without blocking the next import for the process lifetime. The ceiling
    /// (lanes x 1 thread each) is a security bound like the barcode banks'.
    private static let laneCount = 4

    private let lanes: [DispatchQueue]
    private let lock = NSLock()
    private var occupied: [Bool]

    /// Production uses `shared`; tests build a bank small enough to saturate
    /// deterministically.
    init(lanes laneCount: Int) {
        lanes = (0..<laneCount).map {
            DispatchQueue(label: "is.walt.passes.image.decode.\($0)", qos: .userInitiated)
        }
        occupied = Array(repeating: false, count: laneCount)
    }

    /// Submit `work` to a free lane; a full bank refuses (returns without running),
    /// leaving the caller to its deadline.
    func submit(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        guard let free = occupied.firstIndex(of: false) else {
            lock.unlock()
            return
        }
        occupied[free] = true
        lock.unlock()
        lanes[free].async { [weak self] in
            work()
            guard let self else { return }
            self.lock.lock()
            self.occupied[free] = false
            self.lock.unlock()
        }
    }
}

/// `DispatchWorkItem` is not `Sendable`; `cancel()` is documented thread-safe, and
/// this box exposes nothing else (the doc comment is the ADR per repo policy).
private struct DeadlineBox: @unchecked Sendable {
    let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }
}

/// First resolution wins; the loser's call is a no-op (the decode/deadline race).
private final class ResolveOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: T) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: value)
    }
}

private func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let nanos = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    return .nanoseconds(Int(clamping: nanos))
}
