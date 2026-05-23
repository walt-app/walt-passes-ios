import Testing

@testable import PassesUICore

/// Pins the FSI/PDI fence shape. Both `PassesUI`'s security sheets (verbatim
/// URL, phone, email, organization name) and `PassesPDFUI`'s document tile
/// (user-controlled displayLabel) depend on `isolated(s)` returning exactly
/// `FSI + s + PDI`; a future "polish" that drops or reorders the marks would
/// silently weaken every consumer at once. Locking the property here means the
/// failure surfaces in this module's tests before any surface module's
/// screenshot or snapshot pass.
@Suite("BidiIsolationTest")
struct BidiIsolationTests {

    @Test func isolatedWrapsInFsiAndPdi() {
        let wrapped = isolated("hello")
        #expect(wrapped == "\u{2068}hello\u{2069}")
        #expect(wrapped.first == BidiIsolation.fsi)
        #expect(wrapped.last == BidiIsolation.pdi)
    }

    @Test func isolatedAcceptsEmptyStringAndPreservesFence() {
        // A surface should never invoke isolated("") in practice — the empty case
        // is handled by the caller — but if it does, the fence must still be
        // intact so surrounding bidi context cannot reorder later glyphs into the
        // empty span.
        #expect(isolated("") == "\u{2068}\u{2069}")
    }

    @Test func fsiAndPdiAreTheExpectedUnicodeCodePoints() {
        #expect(BidiIsolation.fsi.unicodeScalars.first?.value == 0x2068)
        #expect(BidiIsolation.pdi.unicodeScalars.first?.value == 0x2069)
    }

    @Test func isolatedPreservesEmbeddedBidiContent() {
        // Embedded RTL text (Hebrew "shalom") must survive verbatim inside the
        // isolate; the fence does not modify its contents, only fences them off
        // from surrounding directional context.
        let rtl = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"
        let wrapped = isolated(rtl)
        #expect(wrapped == "\u{2068}\(rtl)\u{2069}")
    }

    @Test func isolatedDoesNotCollapseNestedIsolates() {
        // A caller passing an already-isolated string yields a nested fence; the
        // helper is a pure wrap and must not attempt to detect or normalize
        // existing FSI/PDI marks. The bidi algorithm handles nesting; the helper
        // must not.
        let inner = isolated("a")
        let outer = isolated(inner)
        #expect(outer == "\u{2068}\u{2068}a\u{2069}\u{2069}")
    }

    @Test func namespacedAndFreeFunctionAgree() {
        #expect(isolated("x") == BidiIsolation.isolated("x"))
    }
}
