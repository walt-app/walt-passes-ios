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
        // Returned near the budget, not near the 3s operation.
        #expect(elapsed < .seconds(1))
    }
}
