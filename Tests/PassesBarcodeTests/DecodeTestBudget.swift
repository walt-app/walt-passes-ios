import Foundation

/// Decode budget for suites that assert what the decoder READS, not how fast it reads it.
///
/// The production 5s budget is a slow-loris guard. Coupling these suites to it made them fail on a
/// 3-core runner, where ~41 concurrent Vision decodes contend for the same cores Vision's
/// out-of-process service runs on — the guard correctly reporting a real overrun, in suites not
/// testing it. The budget itself is covered by ``DecodeTimeoutTests`` and by the per-decoder
/// timeout tests.
let generousDecodeBudget: Duration = .seconds(120)

/// An already-expired budget, for asserting that a decoder reports the timeout arm. The deadline
/// lane is idle and fires on an elapsed deadline immediately, against a Vision decode that must
/// still cross an XPC boundary — orders of magnitude of margin, not a race.
let expiredDecodeBudget: Duration = .zero
