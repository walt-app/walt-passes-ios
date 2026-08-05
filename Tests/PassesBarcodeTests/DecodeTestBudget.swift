import Foundation

/// Decode budget for suites asserting what the decoder READS, not how fast. The production budget
/// is a slow-loris guard with its own coverage; coupling these suites to it made them fail under
/// contention rather than on fidelity. See ADR `barcode-decode-1`.
///
/// Also load-bearing for suite isolation: `DecodeTimeoutTests` saturates the one process-global
/// lane bank, and `.serialized` does not order it against sibling suites.
let generousDecodeBudget: Duration = .seconds(120)

/// An already-expired budget, for asserting that a decoder reports the timeout arm. Still a race in
/// principle — both racers are dispatched — but a deadline that fires on an idle queue resolves in
/// nanoseconds against a Vision decode measured in milliseconds. A stubbed instant decode would not
/// keep that margin.
let expiredDecodeBudget: Duration = .zero
