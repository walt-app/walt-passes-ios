import Foundation
import Testing

@testable import PassesBarcode

/// The budget conversion feeding `asyncAfter`. A units error here rescales every decode budget, and
/// the saturation arms are unreachable from the behavioural tests, so they are pinned directly.
@Suite("DispatchInterval")
struct DispatchIntervalTests {
    @Test func convertsWholeSeconds() {
        #expect(dispatchInterval(.seconds(5)) == .nanoseconds(5_000_000_000))
    }

    @Test func convertsSubSecondBudgets() {
        #expect(dispatchInterval(.milliseconds(100)) == .nanoseconds(100_000_000))
        #expect(dispatchInterval(.microseconds(250)) == .nanoseconds(250_000))
    }

    @Test func convertsZeroToAnImmediateDeadline() {
        #expect(dispatchInterval(.zero) == .nanoseconds(0))
    }

    /// A budget already in the past must fire immediately rather than wrapping into a far-future
    /// deadline, which would leave the caller unbounded — the guard silently off.
    @Test func negativeBudgetsStayNegative() {
        #expect(dispatchInterval(.seconds(-1)) == .nanoseconds(-1_000_000_000))
        #expect(dispatchInterval(.milliseconds(-100)) == .nanoseconds(-100_000_000))
    }

    /// Saturates toward the budget's own sign. The negative arm is the load-bearing one: wrapping
    /// would turn an expired budget into a ~292-year deadline.
    @Test func absurdBudgetsSaturateRatherThanWrapOrTrap() {
        #expect(dispatchInterval(.seconds(Int64.max)) == .nanoseconds(.max))
        #expect(dispatchInterval(.seconds(Int64.min)) == .nanoseconds(.min))
    }
}
