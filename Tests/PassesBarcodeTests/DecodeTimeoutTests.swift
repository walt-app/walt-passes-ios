import Foundation
import Testing

@testable import PassesBarcode

/// What a decode ran on, so the assertion can name a context this module owns.
private struct DecodeContext: Sendable {
    let queue: String
    let thread: String?
}

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
/// `.serialized` because these tests contend for one process-global lane bank: the ceiling test
/// deliberately consumes the whole overflow budget, which would starve the saturation test's spill.
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

    /// The no-queue rule must not become an unbounded thread source. A timed-out decode is orphaned
    /// but keeps running, so an image that wedges Vision — untrusted input, re-fed by the per-frame
    /// scan loop — would mint a permanent thread per frame without a ceiling. Past the ceiling
    /// decodes queue again: degraded, but bounded, where the far end of unbounded is a crash.
    @Test func overflowThreadsAreCapped() async {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Twice the ceiling: enough to prove it engaged and to catch a raised one, without
        // paying to drain 300 holders afterwards.
        let submissions = 2 * (decodeLaneCount + decodeMaxOverflowThreads)
        for _ in 0..<submissions {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(120), timeoutValue: "TIMED_OUT") {
                    started.signal()
                    gate.wait()
                    finished.signal()
                    return "REAL"
                }
            }
        }
        let ceiling = decodeLaneCount + decodeMaxOverflowThreads
        // Stops early if the bound is breached; otherwise the window is the cost of proving a
        // negative. One-sided on purpose — a slow runner starting fewer is still under the bound.
        let concurrent = awaitSignals(started, upTo: ceiling + 1, seconds: 1)

        #expect(concurrent <= ceiling, "\(concurrent) ran at once, ceiling is \(ceiling)")

        // Release everything and wait for it to retire, so this test's threads do not bleed into
        // the next one's view of the shared bank.
        for _ in 0..<submissions { gate.signal() }
        #expect(awaitSignals(finished, upTo: submissions, seconds: 30) == submissions)
    }

    /// Lane accounting must survive the ceiling engaging. A plain busy flag under-reports: the
    /// decode holding a lane clears the flag when it finishes, while a decode queued behind it is
    /// still running there, so the lane reads free and the next submit queues behind untracked work.
    /// That false timeout outlives the pressure that caused it — measured 16/16 timing out with
    /// idle lanes available, against 0/16 once lanes count depth instead.
    @Test func laneAccountingSurvivesQueueingPastTheCeiling() async {
        let holdSaturators = DispatchSemaphore(value: 0)
        let holdQueued = DispatchSemaphore(value: 0)
        let saturatorStarted = DispatchSemaphore(value: 0)
        let saturatorDone = DispatchSemaphore(value: 0)
        let saturators = decodeLaneCount + decodeMaxOverflowThreads

        for _ in 0..<saturators {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(120), timeoutValue: "TIMED_OUT") {
                    saturatorStarted.signal()
                    holdSaturators.wait()
                    saturatorDone.signal()
                    return "REAL"
                }
            }
        }
        #expect(awaitSignals(saturatorStarted, upTo: saturators, seconds: 20) == saturators)

        // Past the ceiling now, so these are queued onto lanes behind the holders above.
        for _ in 0..<decodeLaneCount {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(120), timeoutValue: "TIMED_OUT") {
                    holdQueued.wait()
                    return "REAL"
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))

        // Retire every original holder: their completion releases the lane, but the queued decodes
        // are now running on those same lanes.
        for _ in 0..<saturators { holdSaturators.signal() }
        #expect(awaitSignals(saturatorDone, upTo: saturators, seconds: 20) == saturators)
        try? await Task.sleep(for: .milliseconds(300))
        defer { for _ in 0..<decodeLaneCount { holdQueued.signal() } }

        // Pressure has dropped. Every one of these must land on a genuinely free lane.
        var timedOut = 0
        for _ in 0..<decodeLaneCount {
            let result = await withDecodeTimeout(.milliseconds(400), timeoutValue: "TIMED_OUT") { "REAL" }
            if result == "TIMED_OUT" { timedOut += 1 }
        }
        #expect(timedOut == 0, "\(timedOut)/\(decodeLaneCount) timed out with lanes idle")
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
        // Asserted, not discarded: if fewer than `hogs` start, the lanes were never saturated and
        // the check below would pass without exercising the spill path at all — most likely exactly
        // on the loaded runner this test exists for.
        #expect(awaitSignals(occupied, upTo: hogs, seconds: 20) == hogs)
        defer { for _ in 0..<hogs { gate.signal() } }

        // Every lane is now held. A tight budget still has to be enough for an instant operation.
        let result = await withDecodeTimeout(.milliseconds(500), timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }
}
