import Foundation

/// Run `operation` but give up waiting after `duration`, returning `timeoutValue` instead — the
/// app-level analogue of Android's `ProcessKiller` watchdog (ADR `barcode-decode-1`). Android can
/// kill the isolated decode *process*; iOS cannot, so this bounds the *wait*: a slow or hung Vision
/// decode stops blocking the caller at the budget, and its result is discarded.
///
/// Honest about what it can and cannot do: `VNImageRequestHandler.perform` is synchronous and does
/// not observe cancellation mid-flight, so on timeout the operation runs on to completion on a
/// detached task and its result is dropped. That is acceptable because the roster clamp and the
/// bounded ``BoundedImageDecode`` keep the actual work bounded — the timeout exists to bound how
/// long the caller *waits*, not to forcibly reclaim CPU.
///
/// Implemented with a resolve-once continuation rather than a `withTaskGroup` race: a structured
/// group would await *both* children before the closure returns, so the slow operation would still
/// block the caller past the deadline. The two racing tasks here are unstructured, so the caller
/// resumes the instant either the operation finishes or the deadline fires.
func withDecodeTimeout<T: Sendable>(
    _ duration: Duration,
    timeoutValue: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    let operationTask = Task.detached(priority: .userInitiated) { operation() }
    let deadlineTask = Task<Void, Error> { try await Task.sleep(for: duration) }

    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let resolver = ResolveOnce(continuation)
        Task {
            let value = await operationTask.value
            resolver.resolve(value)
            deadlineTask.cancel()
        }
        Task {
            // Sleep throws only when cancelled (the operation won the race); a clean return is
            // the deadline firing first. The operation task is left to finish orphaned.
            if (try? await deadlineTask.value) != nil {
                resolver.resolve(timeoutValue)
            }
        }
    }
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
