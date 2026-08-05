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

    /// Regression for ipass-f8p: the decode must run on a lane this module owns, never on the
    /// cooperative pool. Inspects the lane rather than parking the pool for real — the behavioural
    /// version starves sibling suites, which is this bug's own blast radius.
    @Test func decodeRunsOnAnOwnedLaneNotTheCooperativePool() async {
        let lane = await withDecodeTimeout(.seconds(5), timeoutValue: "TIMED_OUT") {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(lane.hasPrefix(decodeLaneLabelPrefix), "ran on \(lane)")
    }
}
