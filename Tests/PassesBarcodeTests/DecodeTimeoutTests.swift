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
/// `.serialized` orders the tests *in this suite*; the saturation test runs on its own
/// private bank so parallel suites driving the process-global banks cannot perturb it
/// (and it cannot starve them).
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
        // A PRIVATE bank sized like production, so sibling suites decoding against the
        // process-global banks cannot steal a slot mid-test — sharing `.stillImage` here
        // is what made this test misreport sibling contention as 'one hog short' for
        // months. The image lane's suites use the same own-bank pattern.
        let bank = DecodeLanes(
            lanes: decodeLaneCount,
            maxOverflowThreads: decodeMaxOverflowThreads,
            labelPrefix: "is.walt.passes.barcode.decode-test."
        )
        // Past the lane count so the decode below must spill.
        let hogs = decodeLaneCount + 4
        for _ in 0..<hogs {
            Task.detached {
                _ = await withDecodeTimeout(.seconds(60), on: bank, timeoutValue: "TIMED_OUT") {
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
        let stillImage = await withDecodeTimeout(.seconds(5), on: bank, timeoutValue: "TIMED_OUT") {
            "REAL"
        }
        #expect(stillImage == "REAL")
        // Bank isolation is pinned in `LaneBankIsolation`; this test owns only the
        // no-queueing property.
    }

    /// The ImageIO codec step must run inside the bounded wait on a lane this module
    /// owns — the shared primitive decodes EAGERLY, so a facade that ran it before
    /// `withDecodeTimeout` would put unbounded codec work on the cooperative pool
    /// (the ipass-f8p invariant, extended to the codec half).
    @Test func imageIOStepRunsInsideTheBoundedWaitOnAnOwnedExecutor() async {
        nonisolated(unsafe) var ranOn: DecodeContext?
        let decoder = VisionBarcodeImageDecoder(
            config: BarcodeDecodeConfig(),
            boundedDecode: { _, _ in
                ranOn = DecodeContext(
                    queue: String(cString: __dispatch_queue_get_label(nil)),
                    thread: Thread.current.name
                )
                return .rejected(.imageDecodeFailed)
            }
        )
        _ = await decoder.decode(source: .data(Data([0x01])))
        let owned =
            ranOn?.queue.hasPrefix(decodeLaneLabelPrefix) == true
            || ranOn?.thread == decodeOverflowThreadName
        #expect(
            owned,
            "ImageIO step ran on queue=\(ranOn?.queue ?? "never ran") thread=\(ranOn?.thread ?? "unnamed")"
        )
    }
}
