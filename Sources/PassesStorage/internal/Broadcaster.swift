import Foundation

/// A lock-guarded multicast hub behind the repository's `AsyncStream` observation points
/// (`passesStream`, `observeDocuments`, `observeScannableCards`). Mirrors the value side of
/// Android's `MutableStateFlow`: it holds the latest snapshot, replays it to every new
/// subscriber on subscribe, and re-emits to all live subscribers on each `send`.
///
/// `@unchecked Sendable` with an `NSLock` (per the canonical escape-hatch ADR): the stored
/// state is mutated only under the lock and never escapes. A subscriber that drops its
/// iterator is removed via the stream's `onTermination`, so dead continuations do not leak.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Element
    private var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
    private var nextToken = 0

    init(_ initial: Element) {
        current = initial
    }

    /// The latest snapshot. Backs the repository's `var passes` accessor.
    var value: Element {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// A new subscription. Replays the current snapshot immediately, then emits on every
    /// subsequent `send` until the consumer's iterator is dropped (which deregisters it).
    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        lock.lock()
        let token = nextToken
        nextToken += 1
        continuations[token] = continuation
        let snapshot = current
        lock.unlock()
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            self?.remove(token)
        }
        return stream
    }

    /// Update the snapshot and fan it out to every live subscriber.
    func send(_ value: Element) {
        lock.lock()
        current = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(value)
        }
    }

    /// Finish every subscription. Called from `PassRepository.close()`.
    func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    private func remove(_ token: Int) {
        lock.lock()
        continuations[token] = nil
        lock.unlock()
    }
}
