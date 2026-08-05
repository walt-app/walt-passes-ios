import Foundation

/// Run `operation` but give up waiting after `duration`, returning `timeoutValue` instead — the
/// app-level analogue of Android's `ProcessKiller` watchdog (ADR `barcode-decode-1`). Android can
/// kill the isolated decode *process*; iOS cannot, so this bounds the *wait*: a slow or hung Vision
/// decode stops blocking the caller at the budget, and its result is discarded.
///
/// Honest about what it can and cannot do: `VNImageRequestHandler.perform` is synchronous and does
/// not observe cancellation mid-flight, so on timeout the operation runs on to completion on its
/// decode lane and its result is dropped. That is acceptable because the roster clamp and the
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
    private let lanes: [DispatchQueue] = (0..<16)
        .map { DispatchQueue(label: "is.walt.passes.barcode.decode.\($0)", qos: .userInitiated) }
    private let cursor = NSLock()
    private var busy: [Bool]

    private init() {
        busy = Array(repeating: false, count: lanes.count)
    }

    /// A decode NEVER waits behind another decode, so only its own duration can exhaust its budget.
    /// A free lane is reused; when every lane is occupied the work spills to a transient thread
    /// rather than queueing, because a queued decode that never starts is exactly the false timeout
    /// this guard exists to prevent — and a timed-out decode is orphaned but keeps running (Vision
    /// `perform` is non-cancellable), so occupied lanes are not hypothetical. Spilling is bounded by
    /// concurrent demand, which the app controls; untrusted input cannot inflate it.
    private func submit(_ work: @escaping @Sendable () -> Void) {
        cursor.lock()
        let free = busy.firstIndex(of: false)
        if let lane = free { busy[lane] = true }
        cursor.unlock()

        guard let lane = free else {
            let overflow = Thread { work() }
            overflow.stackSize = 512 * 1024
            overflow.start()
            return
        }

        lanes[lane].async { [self] in
            work()
            cursor.lock()
            busy[lane] = false
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
