import Foundation

/// Decode budget for suites asserting what the decoder READS, not how fast. The production budget
/// is a slow-loris guard with its own coverage; coupling these suites to it made them fail under
/// contention rather than on fidelity. See ADR `barcode-decode-1`.
///
/// Load-bearing for suite isolation, not just for these assertions: the decode lanes are one
/// process-global bank, and `DecodeTimeoutTests` deliberately saturates it. `.serialized` orders
/// those tests against each other but not against sibling suites, so this budget is what keeps a
/// fidelity decode from failing while that saturation is in flight. Trim it and those suites start
/// flaking for reasons that have nothing to do with fidelity.
let generousDecodeBudget: Duration = .seconds(120)

/// An already-expired budget, for asserting that a decoder reports the timeout arm. Not a race:
/// the deadline has elapsed before the decode is even submitted.
let expiredDecodeBudget: Duration = .zero
