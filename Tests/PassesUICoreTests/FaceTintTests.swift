import Testing

@testable import PassesUICore

/// Mirror of Android `FaceTintTest` (wpass-80y.5): the shared gate for the
/// consumer-supplied face tints on the scannable face and the document frame.
/// `nil` is the iOS analogue of Compose's `Color.Unspecified`; a specified but
/// fully transparent tint must read as "no tint" — painting it would leave ink
/// derived from luminance 0 over host paint the kernel cannot see.
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
