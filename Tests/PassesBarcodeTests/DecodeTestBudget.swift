import Foundation

/// Decode budget for suites asserting what the decoder READS, not how fast. The production budget
/// is a slow-loris guard with its own coverage; coupling these suites to it made them fail under
/// contention rather than on fidelity. See ADR `barcode-decode-1`.
let generousDecodeBudget: Duration = .seconds(120)

/// An already-expired budget, for asserting that a decoder reports the timeout arm. Not a race:
/// the deadline has elapsed before the decode is even submitted.
let expiredDecodeBudget: Duration = .zero
