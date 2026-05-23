import Testing
import PassesPDFCore

@testable import PassesPDFUI

/// Pure-Swift cover for the `Error -> ConsumerRenderFailure` mapping
/// inside the bitmap-reconstruction helper. Mirror of Android's
/// `ConsumerRenderFailureMappingTest`. Pinning the dispatch table here is
/// what keeps a future refactor from silently re-routing one of the three
/// deterministic failure shapes through the `.other` arm.
@Suite("consumerRenderFailureFor")
struct ConsumerRenderFailureMappingTests {

    @Test func outOfMemoryMapsToOutOfMemory() {
        #expect(consumerRenderFailureFor(OutOfMemoryError()) == .outOfMemory)
    }

    @Test func dimensionMismatchMapsToDimensionMismatch() {
        #expect(consumerRenderFailureFor(DimensionMismatchError()) == .dimensionMismatch)
    }

    @Test func sharedMemoryUnavailableMapsToSharedMemoryUnavailable() {
        #expect(consumerRenderFailureFor(SharedMemoryUnavailableError()) == .sharedMemoryUnavailable)
    }

    @Test func unknownErrorFallsThroughToOther() {
        // Defensive `.other` exists so a future platform change that
        // surfaces a new failure class never crashes the consumer; a
        // spike on this arm in production telemetry is the signal to
        // add a new mapping.
        struct UnknownError: Error {}
        #expect(consumerRenderFailureFor(UnknownError()) == .other)
    }
}
