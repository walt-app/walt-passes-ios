import Foundation
import Testing

@testable import PassesPDFCore

/// The structural lock that makes `DocumentTelemetryGuard` a security control rather
/// than a convenience interface. The doc-comment on the guard claims "enums, counts,
/// and durations only"; this test enforces that claim by *allowlist*, not denylist.
///
/// Allowlist over denylist is deliberate. A denylist test ("no `String` parameter")
/// leaks past the obvious smuggling routes - `Array<String>`, `Set<String>`,
/// `Dictionary<Enum, String>`, `(String, Int64)`, `Data`. Each of those slips a `String`
/// into telemetry while resolving to a wrapper type the denylist would not flag. An
/// allowlist that names every legitimate parameter shape (`Int64`, `Int`, enums, and
/// the event structs themselves) closes that gap structurally: anything else is a test
/// failure, including things future contributors have not invented yet.
///
/// On Kotlin/JVM this is enforced via `java.lang.reflect`. Swift lacks an equivalent
/// dynamic surface for protocol method parameter types (Swift protocols are not
/// reflectable that way), so the equivalent property is enforced two ways:
///
///  1. `Mirror`-based reflection over event struct *stored properties* - the same
///     reachable shape Kotlin's `declaredConstructors` walks. Any stored property whose
///     declared type is not in the allowlist is a violation.
///  2. A meta-test that defines a bad struct (with a `String` field) and proves the
///     `Mirror` walk *would* flag it, demonstrating the allowlist is not vacuous.
@Suite("DocumentTelemetryGuardSurface")
struct DocumentTelemetryGuardSurfaceTests {

    @Test func eventStoredPropertiesAcceptOnlyEnumsAndCountsAndDurations() {
        var violations: [String] = []
        collectViolations(
            for: DocumentImportSucceededEvent(byteCount: 0, pageCount: 0, durationMillis: 0),
            into: &violations
        )
        collectViolations(
            for: DocumentImportFailedEvent(outcome: .encrypted, durationMillis: 0),
            into: &violations
        )
        #expect(violations.isEmpty, "violations=\(violations)")
    }

    /// Meta-test demonstrating the lock is not vacuous: every smuggling shape the
    /// review enumerated (`[String]`, `Set<String>`, `[Enum: String]`, `(String, Int64)`,
    /// `Data`) is rejected by the allowlist. If a future refactor accidentally weakens
    /// the lock, this test fails first and surfaces the issue inside the same file as
    /// the rule it protects.
    @Test func allowlistRejectsKnownStringSmugglingShapes() {
        struct BadListOfString { let tags: [String]; let durationMillis: Int64 }
        struct BadSetOfString { let tags: Set<String>; let durationMillis: Int64 }
        struct BadMapEnumToString {
            let tags: [DocumentRejectedKind: String]
            let durationMillis: Int64
        }
        struct BadTupleOfStringInt { let tag: (String, Int64); let durationMillis: Int64 }
        struct BadByteData { let payload: Data; let durationMillis: Int64 }
        struct BadStringField { let tag: String; let durationMillis: Int64 }

        let cases: [Any] = [
            BadListOfString(tags: [], durationMillis: 0),
            BadSetOfString(tags: [], durationMillis: 0),
            BadMapEnumToString(tags: [:], durationMillis: 0),
            BadTupleOfStringInt(tag: ("x", 0), durationMillis: 0),
            BadByteData(payload: Data(), durationMillis: 0),
            BadStringField(tag: "x", durationMillis: 0),
        ]
        for badCase in cases {
            var violations: [String] = []
            collectViolations(for: badCase, into: &violations)
            #expect(!violations.isEmpty, "expected violations for \(type(of: badCase))")
        }
    }

    /// Walk the stored properties of `subject` and append a violation string for any
    /// property whose value type is not on the allowlist. Allowlist: `Int64`, `Int`,
    /// any enum (detected via `Mirror.displayStyle == .enum`), and the event-struct
    /// shells themselves.
    private func collectViolations(for subject: Any, into violations: inout [String]) {
        let mirror = Mirror(reflecting: subject)
        let subjectName = String(describing: type(of: subject))
        for child in mirror.children {
            let label = child.label ?? "<unlabelled>"
            if !isAllowed(child.value) {
                violations.append("\(subjectName).\(label) has disallowed type \(type(of: child.value))")
            }
        }
    }

    private func isAllowed(_ value: Any) -> Bool {
        // Allow primitive counts and durations.
        if value is Int64 || value is Int { return true }
        // Allow any enum.
        let m = Mirror(reflecting: value)
        if m.displayStyle == .enum { return true }
        return false
    }
}
