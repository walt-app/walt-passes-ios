import Foundation

/// Outcome of the importer's single bounded source read. `oversized` carries the
/// truncated prefix so the importer can still sniff the KIND it is rejecting;
/// the prefix never reaches a backend, a codec, or `persist`.
enum BoundedSourceRead: Sendable {
    case bytes(Data)
    case oversized(prefix: Data)
    case unavailable
}

/// Fixed ceiling on concurrently parked reader threads — a security bound like
/// the decode banks' (`LanePlacement`): a source that never completes parks its
/// thread for the process lifetime, so without a cap each stalled import mints
/// a permanent thread. Past the cap a submission is REFUSED (running nothing)
/// and the caller resolves with the timeout value immediately.
final class SourceReadSlots: @unchecked Sendable {
    static let shared = SourceReadSlots(capacity: defaultCapacity)
    /// Enough to absorb a few wedged providers without blocking the next import;
    /// four parked reads is already a broken environment, not a workload.
    static let defaultCapacity = 4

    private let lock = NSLock()
    private var inFlight = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "a zero-slot lane would refuse every read")
        self.capacity = capacity
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < capacity else { return false }
        inFlight += 1
        return true
    }

    func release() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
}

/// Run a blocking source read off the cooperative pool, giving up the WAIT after
/// `duration` (sibling of the internal `PassesBarcode.withDecodeTimeout`, whose
/// decode-lane slots this deliberately does not consume — a stalled read must
/// not occupy still-image decode capacity). The read runs on a dedicated thread:
/// the cooperative pool is fixed-width, and a stalled provider read would park a
/// pool thread with no deadline, starving unrelated async work app-wide. On
/// timeout the read runs on to completion and its result is dropped — this
/// bounds the caller's wait and (via `slots`) the parked-thread count, not the
/// work.
func withSourceReadDeadline<T: Sendable>(
    _ duration: Duration,
    timeoutValue: T,
    slots: SourceReadSlots = .shared,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        guard slots.claim() else {
            resolver.resolve(timeoutValue)
            return
        }
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        // Dedicated serial queue so a deadline is never queued behind other work
        // (the DecodeLanes.deadlines precedent); resolve is O(1) and never blocks.
        sourceReadDeadlines.asyncAfter(
            deadline: .now() + .nanoseconds(saturatedNanoseconds(duration)),
            execute: deadline.item)
        let reader = Thread {
            // Released when the read RETURNS: a wedged read holds its slot for
            // the process lifetime, exactly like a wedged decode lane — the cap
            // is what turns that from unbounded growth into a bounded refusal.
            defer { slots.release() }
            let value = operation()
            deadline.item.cancel()
            resolver.resolve(value)
        }
        reader.name = "is.walt.passes.document.source-read"
        reader.qualityOfService = .userInitiated
        reader.start()
    }
}

private let sourceReadDeadlines = DispatchQueue(
    label: "is.walt.passes.document.source-read-deadline", qos: .userInitiated)

private func saturatedNanoseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0 else { return 0 }
    let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return .max }
    let (total, carry) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
    guard !carry, let nanoseconds = Int(exactly: total) else { return .max }
    return nanoseconds
}

/// `@unchecked Sendable` box for the deadline work item, which predates
/// `Sendable` (the `DecodeTimeout.DeadlineBox` precedent): `DispatchWorkItem`
/// is internally thread-safe and the only cross-thread call here is `cancel()`.
private final class DeadlineBox: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
}

/// Resumes the continuation exactly once, whichever racer arrives first (the
/// siblings' `ResolveOnce`). `@unchecked Sendable`: the non-`Sendable`
/// continuation is guarded by the lock — only the first `resolve` reads and
/// nils it, so no resume can race or repeat.
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
