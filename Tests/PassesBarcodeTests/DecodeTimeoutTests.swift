import Foundation
import Testing

@testable import PassesBarcode

/// What a decode ran on, so the assertion can name a context this module owns.
private struct DecodeContext: Sendable {
    let queue: String
    let thread: String?
}

/// Non-blocking poll. Wrapped in a sync function only because the compiler bans the call in async
/// contexts; with a `.now()` deadline it never actually blocks.
private func tryTake(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

/// Waits for up to `count` signals, giving up after `seconds` and returning how many arrived.
///
/// Bounded so a regression fails rather than hanging the suite. Yields rather than blocking: a
/// blocking poll holds a cooperative-pool thread and starves the tasks being waited for.
private func awaitSignals(_ semaphore: DispatchSemaphore, upTo count: Int, seconds: Double) async -> Int {
    let deadline = Date().addingTimeInterval(seconds)
    var seen = 0
    while seen < count, Date() < deadline {
        if tryTake(semaphore) {
            seen += 1
        } else {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    return seen
}

/// Coverage for ``withDecodeTimeout(_:timeoutValue:operation:)`` — the app-level `ProcessKiller`
/// analogue. The security-relevant property is that a slow/hung operation stops blocking the caller
/// at the budget and yields the timeout value; the fast path must return the real result untouched.
/// `.serialized` because these tests contend for one process-global lane bank:
/// `decodeDoesNotQueueBehindSaturatedLanes` holds every lane and 8 overflow threads for as long as
/// it takes the runner to start them, so its siblings would run against a bank it has taken.
@Suite("DecodeTimeout", .serialized)
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
        let timedOut = DecodeContext(queue: "TIMED_OUT", thread: nil)
        let ranOn = await withDecodeTimeout(.seconds(5), timeoutValue: timedOut) {
            DecodeContext(
                queue: String(cString: __dispatch_queue_get_label(nil)),
                thread: Thread.current.name
            )
        }
        // Positive, not just "not cooperative": on the spill path the queue label is the runtime's
        // fallback (com.apple.root.default-qos.overcommit), which is not evidence of anything, so
        // the overflow thread is identified by the name this module gives it.
        let owned = ranOn.queue.hasPrefix(decodeLaneLabelPrefix) || ranOn.thread == decodeOverflowThreadName
        #expect(owned, "ran on queue=\(ranOn.queue) thread=\(ranOn.thread ?? "unnamed")")
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
        // Asserted, not discarded: without it the check below could pass on an unsaturated bank,
        // never exercising the spill path — most likely exactly on the loaded runner this test
        // exists for. Waiting on `hogs` would over-require, though: `claim` fills lanes before it
        // spills, so one signal past the lane count already proves every lane is taken. Demanding
        // all 24 starts is an assertion about how fast the runner mints threads, which is the
        // failure mode this suite is being cured of.
        let saturated = decodeLaneCount + 1
        #expect(await awaitSignals(occupied, upTo: saturated, seconds: 20) == saturated)
        defer { for _ in 0..<hogs { gate.signal() } }

        // Every lane is now held. A tight budget still has to be enough for an instant operation.
        let result = await withDecodeTimeout(.milliseconds(500), timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }
}
