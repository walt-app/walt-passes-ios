import Foundation
import Testing

@testable import PassesBarcode

/// The two properties a saturated bank has to hold, exercised against banks small enough to fill
/// deterministically. A production bank is 40 slots, and "40 holders must start" asserts how fast the
/// runner mints threads rather than anything about this code — the flake ADR `barcode-decode-1`
/// records twice. One lane and no spill reaches the same states with one holder.
@Suite("LaneBankIsolation")
struct LaneBankIsolationTests {
    private func oneSlotBank(_ name: String) -> DecodeLanes {
        DecodeLanes(lanes: 1, maxOverflowThreads: 0, labelPrefix: "is.walt.passes.barcode.test.\(name).")
    }

    /// Holds `bank`'s only slot until the returned closure is called, so the next submission to it is
    /// refused. Returns once the holder is genuinely running, not merely submitted.
    private func saturate(_ bank: DecodeLanes) async -> @Sendable () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let running = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await withDecodeTimeout(.seconds(60), on: bank, timeoutValue: "TIMED_OUT") {
                running.signal()
                gate.wait()
                return "REAL"
            }
        }
        #expect(await awaitSignals(running, upTo: 1, seconds: 20) == 1, "the holder must be running")
        return { gate.signal() }
    }

    /// The liveness the refusal path rests on. A refused submission runs nothing, so the only thing
    /// left that can resolve the caller is the deadline scheduled before the submit — an interaction
    /// no other test reaches, because reaching it needs a genuinely full bank. Without it the caller
    /// stays suspended forever, in exactly the saturated state the cap exists for.
    @Test func aRefusedSubmissionStillResolvesItsCallerWithTheTimeoutValue() async {
        let bank = oneSlotBank("refusal")
        let release = await saturate(bank)
        defer { release() }

        let result = await withDecodeTimeout(.milliseconds(200), on: bank, timeoutValue: "TIMED_OUT") {
            "REAL"
        }

        #expect(result == "TIMED_OUT")
    }

    /// A refused submission must not run its operation, since that is what keeps it from retaining
    /// the payload it captured (ipass-ba3).
    @Test func aRefusedSubmissionNeverRunsItsOperation() async {
        let bank = oneSlotBank("dropped")
        let release = await saturate(bank)
        defer { release() }
        let ran = DispatchSemaphore(value: 0)

        _ = await withDecodeTimeout(.milliseconds(200), on: bank, timeoutValue: "TIMED_OUT") {
            ran.signal()
            return "REAL"
        }

        #expect(tryTake(ran) == false)
    }

    /// Saturating one bank must leave another serving instantly. Discriminating where a cross-bank
    /// probe against the real banks is not: this one is genuinely full, so a shared bank would refuse
    /// the second submission rather than serve it.
    @Test func saturatingOneBankLeavesAnotherServing() async {
        let saturated = oneSlotBank("saturated")
        let other = oneSlotBank("other")
        let release = await saturate(saturated)
        defer { release() }

        let result = await withDecodeTimeout(.seconds(5), on: other, timeoutValue: "TIMED_OUT") { "REAL" }

        #expect(result == "REAL")
    }

    /// The wiring the two tests above stand on: the production banks really are separate instances,
    /// so the isolation they demonstrate is the isolation the decoders get.
    @Test func theProductionBanksAreDistinctInstances() {
        #expect(DecodeLanes.bank(.stillImage) !== DecodeLanes.bank(.liveFrame))
        #expect(DecodeLanes.bank(.stillImage) === DecodeLanes.bank(.stillImage))
        #expect(Set(DecodeBank.allCases.map(\.rawValue)).count == DecodeBank.allCases.count)
    }
}
