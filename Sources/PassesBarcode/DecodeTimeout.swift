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
/// NEITHER racer may touch the shared Swift cooperative pool, and that is load-bearing rather than
/// stylistic. The pool is fixed-width and does not grow, so a caller that parks its threads (see
/// `SignatureVerifier.runBlocking`, which documents the same hazard) can keep a pool-scheduled
/// decode from ever STARTING, while the deadline — a timer — still fires on schedule. That made the
/// guard report a timeout for decodes that never ran (ipass-f8p): measured with the pool parked,
/// work submitted via `Task.detached`, a concurrent `DispatchQueue`, or `DispatchQueue.global` had
/// not begun after 20s, while a dedicated serial queue began in 0.1ms.
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

/// The decode lanes and the deadline lane, all dedicated serial queues this module owns.
///
/// A bank rather than one queue: the still-image and live-frame paths decode concurrently, and a
/// single lane would queue them behind each other until the wait they share exceeded its own
/// budget — trading starvation-by-pool for starvation-by-queue. A bank rather than a *concurrent*
/// queue because concurrent queues draw from the same thread pool the cooperative pool exhausts,
/// which is the bug this exists to avoid. Queues create their threads lazily, so idle lanes cost
/// nothing.
///
/// `@unchecked Sendable` because the round-robin cursor is mutable shared state guarded by an
/// `NSLock` — the lock is this type's ADR per the repo's policy; the queues themselves are
/// immutable and `DispatchQueue` is already `Sendable`.
private final class DecodeLanes: @unchecked Sendable {
    private static let shared = DecodeLanes()

    /// Deadlines get their own lane so a timer is never queued behind decode work.
    static let deadlines = DispatchQueue(label: "is.walt.passes.barcode.decode-deadline", qos: .userInitiated)

    static func submit(_ work: @escaping @Sendable () -> Void) {
        shared.submit(work)
    }

    /// One lane per core, floored at 2 so a single-core device still overlaps two decodes.
    private let lanes: [DispatchQueue] = (0..<max(2, ProcessInfo.processInfo.activeProcessorCount))
        .map { DispatchQueue(label: "is.walt.passes.barcode.decode.\($0)", qos: .userInitiated) }
    private let cursor = NSLock()
    private var next = 0

    /// Round-robin so a run of decodes spreads across lanes instead of piling onto one.
    private func submit(_ work: @escaping @Sendable () -> Void) {
        cursor.lock()
        let lane = next
        next = (next + 1) % lanes.count
        cursor.unlock()
        lanes[lane].async(execute: work)
    }
}

/// `DispatchTimeInterval` in nanoseconds, saturating rather than trapping on absurd budgets.
private func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return .nanoseconds(.max) }
    let (total, carryOverflow) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
    guard !carryOverflow, let nanoseconds = Int(exactly: total) else { return .nanoseconds(.max) }
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
