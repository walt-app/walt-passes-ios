import Foundation
import Testing

@testable import PassesUI

let linkScannerTestSource = SourceField(
    fieldKey: "support_url",
    fieldLabel: "Support",
    organizationName: "Acme"
)

enum LinkKind {
    case url, email, phone

    init(_ intent: SecurityIntent) {
        switch intent {
        case .url: self = .url
        case .email: self = .email
        case .phone: self = .phone
        }
    }
}

/// Asserts the scan yields exactly `expected`, in order, each at the UTF-16 range of its
/// first occurrence in `text` and carrying that substring verbatim as its target.
func expectExactSpans(
    _ text: String,
    _ expected: [(String, LinkKind)],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let spans = FieldLinkScanner.scan(text, source: linkScannerTestSource)
    #expect(spans.count == expected.count, "\(text)", sourceLocation: sourceLocation)
    let ns = text as NSString
    for (span, (target, kind)) in zip(spans, expected) {
        let range = ns.range(of: target)
        #expect(span.start == range.location, "\(text)", sourceLocation: sourceLocation)
        #expect(span.endExclusive == range.location + range.length, "\(text)", sourceLocation: sourceLocation)
        #expect(LinkKind(span.intent) == kind, "\(text)", sourceLocation: sourceLocation)
        #expect(actionableTarget(span.intent) == target, "\(text)", sourceLocation: sourceLocation)
    }
}

/// Tripwire for super-linear scans: a quadratic regression on these inputs burns seconds.
func expectLinearScan(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let start = threadCPUMilliseconds()
    _ = FieldLinkScanner.scan(input, source: linkScannerTestSource)
    let cpu = threadCPUMilliseconds() - start
    #expect(cpu < 500, "cpu=\(cpu)ms", sourceLocation: sourceLocation)
}

func codepoint(_ s: String) -> String {
    "U+" + String(s.unicodeScalars.first!.value, radix: 16, uppercase: true)
}

private func actionableTarget(_ intent: SecurityIntent) -> String {
    switch intent {
    case .url(let i): return i.url
    case .email(let i): return i.emailAddress
    case .phone(let i): return i.phoneNumber
    }
}

/// CPU time burned on the calling thread, in milliseconds.
///
/// The catastrophic-backtracking guards measured wall clock and flaked under the parallel
/// suite (ipass-sry): they were reporting the machine's contention, not the scanner's behaviour.
/// A real blowup is super-linear CPU, which this still catches, and `FieldLinkScanner.scan` is a
/// synchronous pure function so none of its work escapes this thread.
func threadCPUMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
}
