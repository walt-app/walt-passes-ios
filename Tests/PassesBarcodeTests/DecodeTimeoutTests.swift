import Foundation
import Testing

@testable import PassesBarcode

/// What a decode ran on, so the assertion can name a context this module owns.
private struct DecodeContext: Sendable {
    let queue: String
    let thread: String?
}

/// Coverage for ``withDecodeTimeout(_:on:timeoutValue:operation:)`` — the app-level `ProcessKiller`
/// analogue. The security-relevant property is that a slow/hung operation stops blocking the caller
/// at the budget and yields the timeout value; the fast path must return the real result untouched.
/// `.serialized` orders the tests *in this suite* against the process-global banks:
/// `decodeDoesNotQueueBehindSaturatedLanes` holds every still-image lane and part of its spill until
/// it finishes. It does NOT hold off other suites — `VisionBarcodeImageDecoderTests` and the
/// hostile-payload suites drive the real decoders in parallel with this one — so the hog count has to
/// leave the still-image bank headroom for them, which that test derives and asserts.
@Suite("DecodeTimeout", .serialized)
struct DecodeTimeoutTests {
    @Test func fastOperationReturnsItsResult() async {
        let result = await withDecodeTimeout(.seconds(5), on: .liveFrame, timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }

    /// Asserts *which* value comes back rather than how fast: had the caller waited on the
    /// operation, this would read "REAL". That bounds the wait by the operation's 3s, not by the
    /// 100ms budget, so it is not a substitute for a timing assertion — but it is immune to runner
    /// speed, which is the flake this suite was cured of. A hang is caught by the test framework.
    @Test func slowOperationYieldsTheTimeoutValueRatherThanWaiting() async {
        let result = await withDecodeTimeout(.milliseconds(100), on: .liveFrame, timeoutValue: "TIMED_OUT") {
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
        let ranOn = await withDecodeTimeout(.seconds(5), on: .liveFrame, timeoutValue: timedOut) {
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
        // Derived, not hand-counted: every prose restatement of this arithmetic has gone stale at
        // least once. Past the lane count so the decode below must spill, and modest because this
        // shares the process-global still-image bank with every sibling suite that decodes an image
        // — and since ipass-ba3 an over-subscribed bank REFUSES rather than queueing, so a hog that
        // loses the race never runs and never signals. The headroom left is asserted below rather
        // than described, which is what kept going stale.
        let hogs = decodeLaneCount + 4
        let headroom = decodeLaneCount + decodeMaxOverflowThreads - hogs
        #expect(headroom >= 24, "sibling suites decode against this bank while these hogs hold it")
        for _ in 0..<hogs {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(60), on: .stillImage, timeoutValue: "TIMED_OUT") {
                    occupied.signal()
                    gate.wait()
                    return "REAL"
                }
            }
        }
        // Asserted, not discarded: an unsaturated bank would never exercise the spill path. Every
        // hog, so the bank is settled rather than still minting spill threads under the probe.
        let started = await awaitSignals(occupied, upTo: hogs, seconds: 20)
        #expect(started == hogs, "hogs that never started were refused, or the runner is saturated")
        defer { for _ in 0..<started { gate.signal() } }

        // Every lane is held and the spill is in use, so this must spill rather than queue. What
        // discriminates is the hogs' 60s hold, not a tight budget: a queued decode cannot return
        // before them, so ANY budget well under 60s catches it. An earlier 500ms budget also
        // measured how fast the runner mints a thread, and failed on the 3-core CI runner while
        // passing locally — precision this assertion never needed.
        let stillImage = await withDecodeTimeout(.seconds(5), on: .stillImage, timeoutValue: "TIMED_OUT") {
            "REAL"
        }
        #expect(stillImage == "REAL")
        // No live-frame probe here: these hogs leave the still-image bank plenty free (the `headroom`
        // asserted above), so a live-frame decode would return instantly under a SHARED bank too.
        // Isolation is pinned in `LaneBankIsolation`.
    }
}
