import Foundation
import Testing

@testable import PassesBarcode

/// Coverage for ``withDecodeTimeout(_:timeoutValue:operation:)`` — the app-level `ProcessKiller`
/// analogue. The security-relevant property is that a slow/hung operation stops blocking the caller
/// at the budget and yields the timeout value; the fast path must return the real result untouched.
@Suite("DecodeTimeout")
struct DecodeTimeoutTests {
    @Test func fastOperationReturnsItsResult() async {
        let result = await withDecodeTimeout(.seconds(5), timeoutValue: "TIMED_OUT") { "REAL" }
        #expect(result == "REAL")
    }

    @Test func slowOperationYieldsTimeoutValuePromptly() async {
        let clock = ContinuousClock()
        let started = clock.now
        // A synchronous op that blocks well past the budget; the caller must not wait for it.
        let result = await withDecodeTimeout(.milliseconds(100), timeoutValue: "TIMED_OUT") {
            Thread.sleep(forTimeInterval: 3)
            return "REAL"
        }
        let elapsed = started.duration(to: clock.now)
        #expect(result == "TIMED_OUT")
        // Returned without waiting on the 3s operation. The bound is generous rather than tight
        // because resuming the caller needs its own executor, which this guard does not control.
        #expect(elapsed < .seconds(2))
    }

    /// Regression for ipass-f8p: the decode must run on a lane this module owns, never on the
    /// shared cooperative pool. That pool is fixed-width and does not grow, so a caller parking
    /// its threads kept the operation from ever starting while the deadline fired on schedule —
    /// reporting a timeout for work never attempted.
    ///
    /// Asserted by inspecting the lane rather than by blocking the pool for real. The behavioural
    /// version passes against this implementation and fails against the old one, but it has to
    /// park every cooperative thread in the process, which starves sibling suites — including
    /// `FieldLinkScannerTests`' sub-500ms assertions. Manufacturing this bug's own blast radius
    /// inside the suite that guards against it is not a trade worth making.
    @Test func decodeRunsOnAnOwnedLaneNotTheCooperativePool() async {
        let lane = await withDecodeTimeout(.seconds(5), timeoutValue: "TIMED_OUT") {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(lane.hasPrefix("is.walt.passes.barcode.decode."), "ran on \(lane)")
    }
}
