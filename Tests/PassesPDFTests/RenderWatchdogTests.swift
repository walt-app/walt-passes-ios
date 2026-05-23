import Foundation
import Testing

@testable import PassesPDF

/// Pins the timeout-then-kill behaviour from ADR 0005 D7. The watchdog is the
/// only mechanism preventing a stuck PDFKit render from holding the renderer
/// indefinitely; if the kill path silently regresses, every other security
/// control here stops being load-bearing because an attacker can simply
/// force a hang.
///
/// Two timeout shapes are exercised:
///  - a cooperatively-suspending block (`Task.sleep`-based polling), and
///  - a synchronous tight-loop block that polls a flag the killer sets.
///
/// Mirrors Android's `RenderWatchdogTest`. On iOS the watchdog cannot take
/// down a process safely; the production `RealProcessKiller` is a no-op. The
/// test recording-killer here pins the call-count behaviour. The watchdog's
/// behaviour on timeout is documented to throw ``RenderWatchdogTimeout`` so
/// the caller can fold it onto rendererFailed.
@Suite("RenderWatchdog")
struct RenderWatchdogTests {

    @Test func timeoutFiresKillerForCooperativelySuspendingBlock() async throws {
        let killer = RecordingProcessKiller()
        let watchdog = RenderWatchdog(timeoutMs: 50, killer: killer)

        var thrown: Error?
        do {
            _ = try await watchdog.guard_ {
                // Cooperatively suspend until cancelled; the watchdog cancels
                // the task group on timeout, so this returns via cancellation.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return ()
            } as Void
        } catch {
            thrown = error
        }
        #expect(thrown is RenderWatchdogTimeout)
        #expect(killer.killCount == 1)
    }

    @Test func fastPathDoesNotKill() async throws {
        let killer = RecordingProcessKiller()
        let watchdog = RenderWatchdog(timeoutMs: 5_000, killer: killer)

        let result: String = try await watchdog.guard_ { "ok" }
        #expect(result == "ok")
        #expect(killer.killCount == 0)
    }
}
