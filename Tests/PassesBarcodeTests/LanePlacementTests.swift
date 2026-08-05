import Foundation
import Testing

@testable import PassesBarcode

/// Placement accounting for the decode lanes, exercised directly at two lanes and a ceiling of one.
///
/// These were integration tests that saturated the real 16-lane bank with 80 live holders. That is
/// how the accounting leak was found, but as a permanent gate it was slow and unreliable: on a
/// 3-core runner "80 saturators must start" is a statement about the runner, and it failed there on
/// code that was correct. The invariants below are pure, so they are pinned deterministically.
@Suite("LanePlacement")
struct LanePlacementTests {
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
        // Ceiling reached: the next one queues rather than minting a third thread.
        #expect(placement.claim() == .lane(0))
        #expect(placement.overflowInFlight == 2)
    }

    @Test func queueingPastTheCeilingRotatesAcrossLanes() {
        var placement = LanePlacement(lanes: 3, maxOverflowThreads: 0)
        for lane in 0..<3 { #expect(placement.claim() == .lane(lane)) }
        // All lanes occupied and no spill allowed, so these queue — spread, not piled on lane 0.
        #expect(placement.claim() == .lane(0))
        #expect(placement.claim() == .lane(1))
        #expect(placement.claim() == .lane(2))
        for lane in 0..<3 { #expect(placement.depth(of: lane) == 2) }
    }

    /// The regression the depth count exists for. A queued decode keeps running on its lane after
    /// the decode it was queued behind completes, so the lane must not read free in between —
    /// otherwise the next submission queues behind untracked work and times out with lanes idle.
    @Test func aQueuedDecodeKeepsItsLaneOccupiedAfterTheOneAheadFinishes() {
        var placement = LanePlacement(lanes: 2, maxOverflowThreads: 0)
        let first = placement.claim()
        _ = placement.claim()
        let queued = placement.claim()
        #expect(first == .lane(0))
        #expect(queued == .lane(0), "precondition: the third claim queues onto lane 0")
        #expect(placement.depth(of: 0) == 2)

        placement.release(first)

        // A busy flag would report lane 0 free here, while `queued` is still executing on it.
        #expect(placement.depth(of: 0) == 1)
    }

    @Test func releasingReturnsCapacityToBothLanesAndOverflow() {
        var placement = LanePlacement(lanes: 1, maxOverflowThreads: 1)
        let lane = placement.claim()
        let overflow = placement.claim()
        #expect(overflow == .overflow)

        placement.release(overflow)
        #expect(placement.overflowInFlight == 0)
        placement.release(lane)
        #expect(placement.depth(of: 0) == 0)
        // Fully drained, so the next claim takes the lane again rather than spilling.
        #expect(placement.claim() == .lane(0))
    }
}
