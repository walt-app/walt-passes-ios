import Foundation

/// Outcome of the importer's single bounded source read. `oversized` carries the
/// truncated prefix so the importer can still sniff the KIND it is rejecting;
/// the prefix never reaches a backend, a codec, or `persist`.
enum BoundedSourceRead: Sendable {
    case bytes(Data)
    case oversized(prefix: Data)
    case unavailable
}

/// Run a blocking source read off the cooperative pool, giving up the WAIT after
/// `duration` (sibling of `PassesBarcode.withDecodeTimeout`, which is internal to
/// that target and whose decode-lane slots this deliberately does not consume —
/// a stalled file-provider read must not occupy still-image decode capacity).
///
/// The read runs on its own dedicated thread — the cooperative pool is
/// fixed-width, and `FileHandle` blocks with no deadline on a stalled provider
/// or a FIFO, so parking a pool thread there can starve unrelated async work
/// app-wide (the elastic-dispatcher placement Android gets from
/// `Dispatchers.IO`). One thread per read, released when the read returns;
/// imports are user-initiated and serial in the app funnel, so the thread count
/// is bounded by use, not by a pool. On timeout the read runs on to completion
/// and its result is dropped — this bounds the caller's wait, not the work.
func withSourceReadDeadline<T: Sendable>(
    _ duration: Duration,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveFirst(continuation)
        let deadline = DeadlineBox(DispatchWorkItem { resolver.resolve(timeoutValue) })
        // Dedicated serial queue so a deadline is never queued behind other work
        // (the DecodeLanes.deadlines precedent); resolve is O(1) and never blocks.
        sourceReadDeadlines.asyncAfter(
            deadline: .now() + .nanoseconds(saturatedNanoseconds(duration)),
            execute: deadline.item)
        let reader = Thread {
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

/// Resumes the continuation exactly once, whichever racer arrives first.
/// `@unchecked Sendable`: the non-`Sendable` continuation is guarded by the
/// lock, which is this type's ADR per the repo's policy — only the first
/// `resolve` reads and nils it, so no resume can race or repeat.
private final class ResolveFirst<T: Sendable>: @unchecked Sendable {
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
