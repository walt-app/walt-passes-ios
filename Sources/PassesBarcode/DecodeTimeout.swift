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

// Configuration for the lane bank below — the source of truth it is built and sized from, not a
// description of it. Internal rather than private so tests name these instead of copying literals;
// the type itself stays private.
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
    private let placementLock = NSLock()
    private var placement = LanePlacement(
        lanes: decodeLaneCount, maxOverflowThreads: decodeMaxOverflowThreads)

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
        placementLock.lock()
        let target = placement.claim()
        placementLock.unlock()

        let release: @Sendable () -> Void = { [self] in
            placementLock.lock()
            placement.release(target)
            placementLock.unlock()
        }

        // Deferred rather than trailing `work()`: a lane or overflow slot leaked here reads as
        // occupied forever, which is a false timeout that outlives its cause.
        switch target {
        case .lane(let lane):
            lanes[lane].async {
                defer { release() }
                work()
            }
        case .overflow:
            let overflow = Thread {
                defer { release() }
                work()
            }
            overflow.qualityOfService = .userInitiated  // Match the lanes; spills happen under load.
            overflow.name = decodeOverflowThreadName
            overflow.start()
        }
    }
}

/// Where each submission goes, and the bookkeeping that decides it. A value type so the accounting
/// is testable without a live lane bank.
struct LanePlacement {
    enum Target: Equatable {
        case lane(Int)
        case overflow
    }

    /// Decodes currently on each lane — a count, not a flag. A flag under-reports once the ceiling
    /// has queued a second decode onto a lane: the first clears it on completion while the queued
    /// one is still running there, so the lane reads free and the next submission queues behind
    /// untracked work, a false timeout outliving the pressure that caused it.
    private var depth: [Int]
    private var overflowThreads = 0
    private var nextQueued = 0
    private let maxOverflowThreads: Int

    init(lanes: Int, maxOverflowThreads: Int) {
        depth = Array(repeating: 0, count: lanes)
        self.maxOverflowThreads = maxOverflowThreads
    }

    /// A free lane if there is one; otherwise a transient thread up to the ceiling; otherwise a
    /// lane to queue on, rotating so the queueing spreads rather than piling onto one.
    mutating func claim() -> Target {
        if let free = depth.firstIndex(of: 0) {
            depth[free] += 1
            return .lane(free)
        }
        if overflowThreads < maxOverflowThreads {
            overflowThreads += 1
            return .overflow
        }
        let lane = nextQueued
        nextQueued = (nextQueued + 1) % depth.count
        depth[lane] += 1
        return .lane(lane)
    }

    mutating func release(_ target: Target) {
        switch target {
        case .lane(let lane): depth[lane] -= 1
        case .overflow: overflowThreads -= 1
        }
    }

    // Read only by the accounting tests; `submit` needs the claim, not the counts.

    /// Decodes in flight on `lane`, including any queued behind the one that is running.
    func depth(of lane: Int) -> Int { depth[lane] }

    var overflowInFlight: Int { overflowThreads }
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
