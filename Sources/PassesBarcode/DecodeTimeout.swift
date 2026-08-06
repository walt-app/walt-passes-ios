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
/// Neither racer may touch the shared Swift cooperative pool: it is fixed-width, so a caller
/// parking its threads can stop a pool-scheduled decode from ever starting while the deadline still
/// fires, reporting a timeout for work never attempted. See ADR `barcode-decode-1` (ipass-f8p).
///
/// `bank` picks which of the two isolated lane banks runs the decode; the untrusted still-image path
/// and the live camera path never share capacity (ipass-9tv). A submission arriving at a full bank is
/// refused rather than queued, and the deadline reports it as a timeout (ipass-ba3).
func withDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    on bank: DecodeBank,
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
        DecodeLanes.submit(bank) {
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
    }
}

/// Which lane bank a decode runs on. The banks are isolated because their inputs carry different
/// trust: enough wedging still-image imports would otherwise consume every slot the live camera
/// scanner needs. A decode that overruns its budget still releases its slot when it finishes; only
/// one that never returns holds it for the life of the process, which is what makes that starvation
/// permanent (ADR `barcode-decode-1`, ipass-9tv).
enum DecodeBank: String, CaseIterable, Sendable {
    /// User-supplied files arriving via the share sheet or the photo picker.
    case stillImage = "still"
    /// Camera frames the app captured itself.
    case liveFrame = "frame"
}

// Configuration each lane bank is built and sized from. Internal so tests name these rather than
// copying literals. Per bank, not process-wide: the documented ceiling covers every bank together.
let decodeLaneCount = 8
let decodeMaxOverflowThreads = 32
let decodeLaneLabelPrefix = "is.walt.passes.barcode.decode."
let decodeOverflowThreadName = "is.walt.passes.barcode.decode.overflow"

/// Dedicated serial queues this module owns — never the cooperative pool, and never a *concurrent*
/// queue, which draws from the same thread pool the cooperative pool exhausts. See ADR
/// `barcode-decode-1`.
///
/// `@unchecked Sendable`: lane occupancy is mutable shared state guarded by an `NSLock`, which is
/// this type's ADR per the repo's policy. The queues themselves are immutable and already `Sendable`.
private final class DecodeLanes: @unchecked Sendable {
    private static let stillImage = DecodeLanes(bank: .stillImage)
    private static let liveFrame = DecodeLanes(bank: .liveFrame)

    /// Deadlines get their own lane so a timer is never queued behind decode work. One shared queue
    /// is enough because `resolve` is O(1) and never blocks, so deadlines cannot starve each other.
    /// Shared across banks for the same reason: a deadline does no work a bank could starve.
    static let deadlines = DispatchQueue(label: "is.walt.passes.barcode.decode-deadline", qos: .userInitiated)

    static func submit(_ bank: DecodeBank, _ work: @escaping @Sendable () -> Void) {
        switch bank {
        case .stillImage: stillImage.submit(work)
        case .liveFrame: liveFrame.submit(work)
        }
    }

    /// Queues create their threads on first use, so an idle bank costs nothing — which is what makes
    /// running two of them affordable.
    private let lanes: [DispatchQueue]
    private let placementLock = NSLock()
    private var placement = LanePlacement(
        lanes: decodeLaneCount, maxOverflowThreads: decodeMaxOverflowThreads)

    private init(bank: DecodeBank) {
        lanes = (0..<decodeLaneCount).map {
            DispatchQueue(label: "\(decodeLaneLabelPrefix)\(bank.rawValue).\($0)", qos: .userInitiated)
        }
    }

    /// A decode never waits behind another decode, so only its own duration can exhaust its budget;
    /// spilling past a full bank is capped because the wedging input is untrusted, and a submission
    /// past that cap is refused rather than queued. All three invariants and their measurements are
    /// argued in ADR `barcode-decode-1`.
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
        case .refused:
            // Dropping `work` here releases the payload it captured — a `CGImage` up to the ~50MP
            // `BoundedImageDecode` limit, or a camera `CVPixelBuffer`. Queueing it instead is what
            // made retention unbounded (ipass-ba3). The caller is resolved by its own deadline.
            break
        }
    }
}

/// Where each submission goes, and the bookkeeping that decides it. A value type so the accounting
/// is testable without a live lane bank.
struct LanePlacement {
    enum Target: Equatable {
        case lane(Int)
        case overflow
        /// The bank is full. The submission runs nowhere and is retained by nothing.
        case refused
    }

    /// Whether each lane is running a decode. A flag rather than a count because nothing is ever
    /// placed on an occupied lane: `claim` refuses instead of queueing, which is the invariant
    /// `refusesRatherThanQueueingOntoAnOccupiedLane` exists to pin (ADR `barcode-decode-1`).
    private var occupied: [Bool]
    private var overflowThreads = 0
    private let maxOverflowThreads: Int

    init(lanes: Int, maxOverflowThreads: Int) {
        precondition(lanes > 0, "a bank needs at least one lane")
        occupied = Array(repeating: false, count: lanes)
        self.maxOverflowThreads = maxOverflowThreads
    }

    /// A free lane if there is one; otherwise a transient thread up to the ceiling; otherwise
    /// nothing. Total in-flight work is therefore capped at `lanes + maxOverflowThreads`.
    mutating func claim() -> Target {
        if let free = occupied.firstIndex(of: false) {
            occupied[free] = true
            return .lane(free)
        }
        if overflowThreads < maxOverflowThreads {
            overflowThreads += 1
            return .overflow
        }
        return .refused
    }

    mutating func release(_ target: Target) {
        switch target {
        case .lane(let lane): occupied[lane] = false
        case .overflow: overflowThreads -= 1
        case .refused: break  // Claimed nothing, so there is nothing to give back.
        }
    }

    // Read only by the accounting tests; `submit` needs the claim, not the counts.

    func isOccupied(_ lane: Int) -> Bool { occupied[lane] }

    var overflowInFlight: Int { overflowThreads }
}

/// `DispatchTimeInterval` in nanoseconds, saturating rather than trapping on absurd budgets.
/// Saturates toward the budget's own sign, so a negative one fires immediately instead of
/// wrapping into a ~292-year deadline. Internal so the saturation arms are directly testable.
func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
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
