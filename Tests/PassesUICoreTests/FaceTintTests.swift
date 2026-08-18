import Testing

@testable import PassesUICore

/// Mirror of Android `FaceTintTest` (wpass-80y.5). The transparent case and
/// why it must read as "no tint" — see `FaceTint.swift`, the canonical copy.
struct FaceTintTests {

    @Test func nilIsNotTinted() {
        #expect(!faceIsTinted(nil))
    }

    @Test func fullyTransparentIsNotTinted() {
        #expect(!faceIsTinted(ArgbColor(argb: 0x00FF_D8D5)))
    }

    @Test func opaqueIsTinted() {
        #expect(faceIsTinted(ArgbColor(argb: 0xFFBF_EEEA)))
    }

    @Test func anyVisibleAlphaIsTinted() {
        #expect(faceIsTinted(ArgbColor(argb: 0x0100_0000)))
    }
}
