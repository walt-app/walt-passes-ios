import Foundation
import Testing

@testable import PassesBarcode

/// Waits for up to `count` signals but gives up after `seconds`, returning how many arrived.
/// Bounded on purpose: an unbounded wait turns a regression into a hung suite instead of a failing
/// test, since the whole point of the assertion is that some submissions may never start.
/// Synchronous because the compiler bans blocking waits in async contexts.
private func awaitSignals(_ semaphore: DispatchSemaphore, upTo count: Int, seconds: Double) -> Int {
    let deadline = Date().addingTimeInterval(seconds)
    var seen = 0
    while seen < count, Date() < deadline {
        if semaphore.wait(timeout: .now() + 0.05) == .success { seen += 1 }
    }
    return seen
}

/// Coverage for ``withDecodeTimeout(_:timeoutValue:operation:)`` — the app-level `ProcessKiller`
/// analogue. The security-relevant property is that a slow/hung operation stops blocking the caller
/// at the budget and yields the timeout value; the fast path must return the real result untouched.
@Suite("DecodeTimeout")
struct DecodeTimeoutTests {
    @Test func fastOperationReturnsItsResult() async {
        let result = await withDecodeTimeout(.seconds(5), timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }

    /// Exact, and strictly stronger than any elapsed-time bound: had the caller waited on the
    /// operation, the operation would have won the race and this would read "REAL". A hang is
    /// caught by the test framework's own timeout.
    @Test func slowOperationYieldsTheTimeoutValueRatherThanWaiting() async {
        let result = await withDecodeTimeout(.milliseconds(100), timeoutValue: "TIMED_OUT") {
            Thread.sleep(forTimeInterval: 3)
            return "REAL"
        }
        #expect(result == "TIMED_OUT")
    }

    /// Regression for ipass-f8p: the decode must never run on the cooperative pool, which the old
    /// implementation did (`com.apple.root.user-initiated-qos.cooperative`). Asserted negatively
    /// because a decode legitimately runs either on a lane or, under saturation, on an overflow
    /// thread. Inspects where it ran rather than parking the pool for real — the behavioural
    /// version starves sibling suites, which is this bug's own blast radius.
    @Test func decodeNeverRunsOnTheCooperativePool() async {
        let ranOn = await withDecodeTimeout(.seconds(5), timeoutValue: "TIMED_OUT") {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(!ranOn.contains("cooperative"), "ran on \(ranOn)")
    }

    /// A decode must never queue behind another decode: only its OWN duration may exhaust its
    /// budget. Timed-out decodes are orphaned but keep running, so occupied lanes are normal, and a
    /// bounded bank alone would turn a burst into false timeouts — which is what made this suite
    /// flake on CI even after the pool fix.
    @Test func decodeDoesNotQueueBehindSaturatedLanes() async {
        let gate = DispatchSemaphore(value: 0)
        let occupied = DispatchSemaphore(value: 0)
        // Occupy well past the lane count so the overflow path is what serves the decode below.
        let hogs = 24
        for _ in 0..<hogs {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(60), timeoutValue: "TIMED_OUT") {
                    occupied.signal()
                    gate.wait()
                    return "REAL"
                }
            }
        }
        _ = awaitSignals(occupied, upTo: hogs, seconds: 5)
        defer { for _ in 0..<hogs { gate.signal() } }

        // Every lane is now held. A tight budget still has to be enough for an instant operation.
        let result = await withDecodeTimeout(.milliseconds(500), timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }
}
