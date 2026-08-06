import Foundation
import Testing

@testable import PassesBarcode

/// Placement accounting for the decode lanes, exercised directly at small lane counts and ceilings
/// so the invariants are pinned deterministically rather than by saturating the real bank.
@Suite("LanePlacement")
struct LanePlacementTests {
    /// The bank's thread ceiling is a security bound, not tidiness (ADR `barcode-decode-1`): a
    /// timed-out decode is orphaned but keeps running, so an image crafted to wedge Vision, re-fed
    /// by the per-frame scan loop, mints a thread per frame against whatever this permits.
    /// Asserted as a bound rather than an equality so lowering it stays free and only raising it
    /// has to be deliberate.
    @Test func theBankCannotOutgrowItsDocumentedThreadCeiling() {
        // Every bank together, not one: isolating the two paths (ipass-9tv) multiplies this.
        #expect(DecodeBank.allCases.count * (decodeLaneCount + decodeMaxOverflowThreads) <= 80)
    }

    @Test func reusesFreeLanesBeforeSpilling() {
        var placement = LanePlacement(lanes: 2, maxOverflowThreads: 1)
        #expect(placement.claim() == .lane(0))
        #expect(placement.claim() == .lane(1))
        #expect(placement.overflowInFlight == 0)
    }

    @Test func spillsOnlyUntilTheCeiling() {
        var placement = LanePlacement(lanes: 2, maxOverflowThreads: 2)
        _ = placement.claim()
        _ = placement.claim()
        #expect(placement.claim() == .overflow)
        #expect(placement.claim() == .overflow)
        #expect(placement.overflowInFlight == 2)
        // Ceiling reached: the next one is refused rather than minting a third thread.
        #expect(placement.claim() == .refused)
        #expect(placement.overflowInFlight == 2)
    }

    /// The retention bound (ipass-ba3). Queueing onto an occupied lane is what let a full bank
    /// accumulate submissions without limit, each pinning the payload it captured — a `CGImage` up
    /// to the ~50MP bounded-decode cap, or a camera pixel buffer — behind a lane head a wedged
    /// decode never releases. Refusing retains nothing, so the far end is no longer jetsam.
    @Test func refusesRatherThanQueueingOntoAnOccupiedLane() {
        var placement = LanePlacement(lanes: 3, maxOverflowThreads: 0)
        for lane in 0..<3 { #expect(placement.claim() == .lane(lane)) }
        // All lanes occupied and no spill allowed: every further claim is refused, indefinitely.
        for _ in 0..<10 { #expect(placement.claim() == .refused) }
        for lane in 0..<3 { #expect(placement.isOccupied(lane)) }
    }

    /// A refusal claimed nothing, so releasing it must not hand back capacity that was never taken —
    /// which would read as a free lane and place the next decode on top of a running one.
    @Test func releasingARefusalDoesNotInventCapacity() {
        var placement = LanePlacement(lanes: 1, maxOverflowThreads: 1)
        _ = placement.claim()
        _ = placement.claim()
        let refused = placement.claim()
        #expect(refused == .refused)

        placement.release(refused)

        #expect(placement.isOccupied(0))
        #expect(placement.overflowInFlight == 1)
        #expect(placement.claim() == .refused)
    }

    @Test func releasingReturnsCapacityToBothLanesAndOverflow() {
        var placement = LanePlacement(lanes: 1, maxOverflowThreads: 1)
        let lane = placement.claim()
        let overflow = placement.claim()
        #expect(overflow == .overflow)

        placement.release(overflow)
        #expect(placement.overflowInFlight == 0)
        placement.release(lane)
        #expect(placement.isOccupied(0) == false)
        // Fully drained, so the next claim takes the lane again rather than spilling.
        #expect(placement.claim() == .lane(0))
    }
}
