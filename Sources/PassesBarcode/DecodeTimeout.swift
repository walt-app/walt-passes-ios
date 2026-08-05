import Foundation

/// Run `operation` but give up waiting after `duration`, returning `timeoutValue` instead — the
/// app-level analogue of Android's `ProcessKiller` watchdog (ADR `barcode-decode-1`). Android can
/// kill the isolated decode *process*; iOS cannot, so this bounds the *wait*: a slow or hung Vision
/// decode stops blocking the caller at the budget, and its result is discarded.
///
/// Honest about what it can and cannot do: `VNImageRequestHandler.perform` is synchronous and does
/// not observe cancellation mid-flight, so on timeout the operation runs on to completion wherever
/// it was placed and its result is dropped. That is acceptable because the roster clamp and the
/// bounded ``BoundedImageDecode`` keep the actual work bounded — the timeout exists to bound how
/// long the caller *waits*, not to forcibly reclaim CPU.
///
/// Implemented with a resolve-once continuation rather than a `withTaskGroup` race: a structured
/// group would await *both* children before the closure returns, so the slow operation would still
/// block the caller past the deadline.
///
/// Neither racer may touch the shared Swift cooperative pool: it is fixed-width, so a caller
/// parking its threads can stop a pool-scheduled decode from ever starting while the deadline still
/// fires, reporting a timeout for work never attempted. See ADR `barcode-decode-1` (ipass-f8p).
func withDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        DecodeLanes.deadlines.asyncAfter(
            deadline: .now() + dispatchInterval(duration),
            execute: deadline.item
        )
        DecodeLanes.submit {
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
    }
}

// Test seams describing the private lane bank below, so tests name symbols instead of copying
// literals. Internal rather than exposing the type itself, which stays private.
let decodeLaneCount = 16
let decodeMaxOverflowThreads = 64
let decodeLaneLabelPrefix = "is.walt.passes.barcode.decode."
let decodeOverflowThreadName = "is.walt.passes.barcode.decode.overflow"

/// Dedicated serial queues this module owns — never the cooperative pool, and never a *concurrent*
/// queue, which draws from the same thread pool the cooperative pool exhausts. See ADR
/// `barcode-decode-1`.
///
/// `@unchecked Sendable`: lane occupancy is mutable shared state guarded by an `NSLock`, which is
/// this type's ADR per the repo's policy. The queues themselves are immutable and already `Sendable`.
private final class DecodeLanes: @unchecked Sendable {
    private static let shared = DecodeLanes()

    /// Deadlines get their own lane so a timer is never queued behind decode work.
    static let deadlines = DispatchQueue(label: "is.walt.passes.barcode.decode-deadline", qos: .userInitiated)

    static func submit(_ work: @escaping @Sendable () -> Void) {
        shared.submit(work)
    }

    /// Warm lanes for the common case. Vision decodes out of process, so a lane mostly waits on
    /// that service; queues create their threads lazily, so idle lanes cost nothing.
    private let lanes: [DispatchQueue] = (0..<decodeLaneCount)
        .map { DispatchQueue(label: "\(decodeLaneLabelPrefix)\($0)", qos: .userInitiated) }
    private let cursor = NSLock()
    /// How many decodes are on each lane, not merely whether one is. A plain busy flag under-reports
    /// once the ceiling has queued a second decode onto a lane: the first decode clears the flag when
    /// it finishes while the queued one is still running, so the lane reads free and the next submit
    /// queues behind untracked work — a false timeout surviving long after pressure dropped.
    private var depth: [Int]
    private var overflowThreads = 0
    private var nextQueued = 0

    private init() {
        depth = Array(repeating: 0, count: lanes.count)
    }

    /// A decode never waits behind another decode, so only its own duration can exhaust its budget.
    /// A free lane is reused; when every lane is occupied the work spills to a transient thread
    /// rather than queueing, because a queued decode that never starts is exactly the false timeout
    /// this guard exists to prevent.
    ///
    /// Spilling is capped. Occupied lanes are the normal case, not a corner — a timed-out decode is
    /// orphaned but keeps running, since Vision `perform` is non-cancellable — so an image that
    /// wedges Vision, re-fed by the per-frame scan loop, would otherwise mint a permanent thread per
    /// frame. That input is untrusted, which makes the ceiling a security bound rather than tidiness.
    private func submit(_ work: @escaping @Sendable () -> Void) {
        cursor.lock()
        let lane: Int?
        if let free = depth.firstIndex(of: 0) {
            lane = free
        } else if overflowThreads < decodeMaxOverflowThreads {
            overflowThreads += 1
            lane = nil
        } else {
            // Past the ceiling: spread the queueing rather than piling every decode onto one lane.
            lane = nextQueued
            nextQueued = (nextQueued + 1) % lanes.count
        }
        if let lane { depth[lane] += 1 }
        cursor.unlock()

        guard let lane else {
            let overflow = Thread { [self] in
                work()
                cursor.lock()
                overflowThreads -= 1
                cursor.unlock()
            }
            overflow.qualityOfService = .userInitiated  // Match the lanes; spills happen under load.
            overflow.name = decodeOverflowThreadName
            overflow.start()
            return
        }

        lanes[lane].async { [self] in
            work()
            cursor.lock()
            depth[lane] -= 1
            cursor.unlock()
        }
    }
}

/// `DispatchTimeInterval` in nanoseconds, saturating rather than trapping on absurd budgets.
/// Saturates toward the budget's own sign, so a negative one fires immediately instead of
/// wrapping into a ~292-year deadline.
private func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let saturated: DispatchTimeInterval = .nanoseconds(seconds < 0 ? .min : .max)
    let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return saturated }
    let (total, carryOverflow) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
    guard !carryOverflow, let nanoseconds = Int(exactly: total) else { return saturated }
    return .nanoseconds(nanoseconds)
}

/// `@unchecked Sendable` box for the deadline work item, which predates `Sendable`. The box is
/// this type's ADR per the repo's policy: `DispatchWorkItem` is internally thread-safe and the only
/// call made across threads here is `cancel()`.
private final class DeadlineBox: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
}

/// Resumes a `CheckedContinuation` exactly once, whichever racer arrives first. `@unchecked
/// Sendable` because it wraps the non-`Sendable` continuation guarded by an `NSLock` — the lock is
/// this type's ADR per the repo's `@unchecked Sendable` policy: only the first `resolve` reads and
/// nils the continuation under the lock, so no resume can race or repeat.
private final class ResolveOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
