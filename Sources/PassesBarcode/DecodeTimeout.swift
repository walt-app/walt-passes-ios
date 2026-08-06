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
    await withDecodeTimeout(
        duration,
        on: DecodeLanes.bank(bank),
        timeoutValue: timeoutValue,
        operation: operation
    )
}

/// Overload taking the bank itself, so tests can build one small enough to saturate deterministically
/// — a full bank is 40 slots, and "40 holders must start" asserts runner speed, not this code.
func withDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    on lanes: DecodeLanes,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        // Scheduled before the submission, not after: a refused submission runs nothing, so this is
        // the only thing left that can resolve the caller.
        DecodeLanes.deadlines.asyncAfter(
            deadline: .now() + dispatchInterval(duration),
            execute: deadline.item
        )
        lanes.submit {
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
    }
}

/// Which lane bank a decode runs on. Isolated per trust level: a decode Vision never returns from
/// holds its slot for the life of the process, so a shared bank let wedging imports starve the
/// camera permanently (ADR `barcode-decode-1`).
enum DecodeBank: String, CaseIterable, Sendable {
    case stillImage = "still"
    case liveFrame = "frame"
}

// Sizing is per bank, so the documented ceiling is this times `DecodeBank.allCases`.
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
final class DecodeLanes: @unchecked Sendable {
    private static let stillImage = DecodeLanes(bank: .stillImage)
    private static let liveFrame = DecodeLanes(bank: .liveFrame)

    /// Deadlines get their own lane so a timer is never queued behind decode work. One shared queue
    /// is enough because `resolve` is O(1) and never blocks, so deadlines cannot starve each other.
    static let deadlines = DispatchQueue(label: "is.walt.passes.barcode.decode-deadline", qos: .userInitiated)

    static func bank(_ bank: DecodeBank) -> DecodeLanes {
        switch bank {
        case .stillImage: stillImage
        case .liveFrame: liveFrame
        }
    }

    private let lanes: [DispatchQueue]
    private let placementLock = NSLock()
    private var placement: LanePlacement

    /// Queues create their threads on first use, so an idle bank costs nothing.
    ///
    /// Production banks must come from ``bank(_:)``, because the documented thread ceiling is a
    /// security bound and the test enforcing it sums over ``DecodeBank`` — a bank built directly
    /// here is outside that sum. This initializer exists so tests can build one small enough to
    /// saturate deterministically.
    init(lanes laneCount: Int, maxOverflowThreads: Int, labelPrefix: String) {
        lanes = (0..<laneCount).map {
            DispatchQueue(label: "\(labelPrefix)\($0)", qos: .userInitiated)
        }
        placement = LanePlacement(lanes: laneCount, maxOverflowThreads: maxOverflowThreads)
    }

    private convenience init(bank: DecodeBank) {
        self.init(
            lanes: decodeLaneCount,
            maxOverflowThreads: decodeMaxOverflowThreads,
            labelPrefix: "\(decodeLaneLabelPrefix)\(bank.rawValue)."
        )
    }

    /// A decode never waits behind another decode, so only its own duration can exhaust its budget.
    /// Spilling is capped, and past the cap a submission is refused rather than queued (ADR
    /// `barcode-decode-1`).
    func submit(_ work: @escaping @Sendable () -> Void) {
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
            // Dropping `work` releases the payload it captured; the caller is resolved by its own
            // deadline.
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

    /// A flag rather than a count because `claim` refuses instead of queueing, so a lane is binary.
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
