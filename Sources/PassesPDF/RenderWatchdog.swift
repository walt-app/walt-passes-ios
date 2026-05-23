import Foundation

/// The timeout-then-kill behaviour mirrored from Android's
/// `RenderWatchdog` (ADR 0005 D7). On Android, PDFium's render path can hang
/// on pathological documents; the watchdog enforces a hard wall-clock budget
/// and, on expiry, terminates the renderer process. The main process then
/// observes the dropped binder as a `RemoteException` and surfaces
/// ``PassesPDFCore/DocumentRejectedKind/rendererFailed``.
///
/// On iOS the renderer (PDFKit) is in-process and cannot be safely killed,
/// so the watchdog instead races the guarded work against a sibling timer:
/// whichever finishes first wins. If the timer wins, the watchdog throws
/// ``RenderWatchdogTimeout`` and the caller folds it onto
/// ``PassesPDFCore/DocumentRejectedKind/rendererFailed``. The sibling
/// killer hook is preserved so test code can pin the same timeout path the
/// Android tests do.
///
/// The kill timer is launched as a *sibling* of the guarded work, not as
/// code that runs after the block returns. Same load-bearing reason as on
/// Android: the production block is a synchronous PDFKit call whose
/// cancellation is cooperative at best; a sibling task whose own sleep runs
/// on the Swift Concurrency timer fires regardless of what the block is
/// doing. If the block returns first, the sibling timer is cancelled and no
/// kill is recorded.
package struct RenderWatchdogTimeout: Error, Sendable {}

package final class RenderWatchdog: Sendable {
    private let timeoutMs: Int64
    private let killer: ProcessKiller

    package init(timeoutMs: Int64, killer: ProcessKiller = RealProcessKiller()) {
        self.timeoutMs = timeoutMs
        self.killer = killer
    }

    /// Race `block` against the timeout. Returns the block's value on the
    /// fast path; throws ``RenderWatchdogTimeout`` after recording a kill if
    /// the timer wins.
    package func guard_<T: Sendable>(block: @Sendable @escaping () async throws -> T) async throws -> T {
        let timeoutMs = self.timeoutMs
        let killer = self.killer
        return try await withThrowingTaskGroup(of: GuardOutcome<T>.self) { group in
            group.addTask {
                let value = try await block()
                return .value(value)
            }
            group.addTask {
                let ns = UInt64(timeoutMs) * 1_000_000
                try await Task.sleep(nanoseconds: ns)
                killer.killSelf()
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RenderWatchdogTimeout()
            }
            switch first {
            case .value(let v):
                return v
            case .timedOut:
                throw RenderWatchdogTimeout()
            }
        }
    }

    private enum GuardOutcome<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }
}
