import Foundation
import PassesImageDecode

/// Bounded WAIT for the image-document decode — the §7-priced translation of
/// Android's `DecodeWatchdog` (which kills its sandbox process; in-process iOS
/// cannot, so on expiry the caller is released with `timeoutValue` and the orphaned
/// work runs to completion on its lane, its result discarded). The header caps in
/// `BoundedRasterDecoder` are what keep the actual work bounded; this bounds how
/// long the caller waits. Same discipline as `PassesBarcode`'s `withDecodeTimeout`,
/// with deliberately SEPARATE bank instances: the image-document lane and the
/// barcode lanes must never share capacity, so a wedged import cannot starve the
/// camera (`docs/adr/image-decode-1.md` records the sizing and the mapping).
///
/// Neither racer touches the Swift cooperative pool: decodes run on this module's
/// own serial lanes, deadlines on their own queue. A submission arriving with every
/// lane occupied is REFUSED — and resolved with `timeoutValue` immediately, not
/// after the full budget (a refusal is known synchronously; making the caller wait
/// out the deadline for it was K2 review round 1's blocker).
func withImageDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    lanes: ImageDecodeLanes = .shared,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        // Scheduled before the submission so the wedged-decode path always has a
        // live resolver.
        ImageDecodeLanes.deadlines.asyncAfter(
            deadline: .now() + saturatingDispatchInterval(duration), execute: deadline.item)
        let accepted = lanes.submit {
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
        if !accepted {
            deadline.item.cancel()
            resolver.resolve(timeoutValue)
        }
    }
}

/// Dedicated serial decode lanes this module owns — never the cooperative pool and
/// never a concurrent queue (which draws from the same thread pool the cooperative
/// pool exhausts). Occupancy is tracked so a full bank REFUSES a submission instead
/// of queueing it behind a possibly-wedged decode; the refusal resolves the caller
/// immediately (see `withImageDecodeTimeout`). No overflow-thread tier, unlike the
/// barcode banks: the sizing bounds this lane's concurrent decode allocation, and
/// the import surface is single-flight UX (ADR records the pricing).
///
/// `@unchecked Sendable`: occupancy is mutable shared state guarded by an `NSLock`
/// (the doc comment is the ADR per the repo's policy); the queues themselves are
/// immutable.
final class ImageDecodeLanes: @unchecked Sendable {
    static let shared = ImageDecodeLanes(lanes: laneCount)
    static let deadlines = DispatchQueue(
        label: "is.walt.passes.image.decode-deadline", qos: .userInitiated)

    /// One import decodes at a time in practice; the extra lanes absorb a wedged
    /// decode without blocking the next import for the process lifetime. The
    /// ceiling (lanes x 1 thread each, and lanes x the decode allocation bound) is
    /// a security bound like the barcode banks'.
    private static let laneCount = 4

    private let lanes: [DispatchQueue]
    private let lock = NSLock()
    private var occupied: [Bool]

    /// Production uses `shared`; tests build a bank small enough to saturate — or
    /// private enough not to contend — deterministically.
    init(lanes laneCount: Int) {
        precondition(laneCount > 0, "a zero-lane bank would refuse every decode")
        lanes = (0..<laneCount).map {
            DispatchQueue(label: "is.walt.passes.image.decode.\($0)", qos: .userInitiated)
        }
        occupied = Array(repeating: false, count: laneCount)
    }

    /// Submit `work` to a free lane; returns `false` (running nothing) when every
    /// lane is occupied. The lane releases in a `defer` and captures `self`
    /// strongly — a lane leaked here would read as occupied forever, a false
    /// refusal that outlives its cause.
    func submit(_ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard let free = occupied.firstIndex(of: false) else {
            lock.unlock()
            return false
        }
        occupied[free] = true
        lock.unlock()
        lanes[free].async {
            defer {
                self.lock.lock()
                self.occupied[free] = false
                self.lock.unlock()
            }
            work()
        }
        return true
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

/// First resolution wins; the loser's call is a no-op (the decode/deadline/refusal
/// race).
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
