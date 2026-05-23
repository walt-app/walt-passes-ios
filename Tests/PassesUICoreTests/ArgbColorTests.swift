import Testing

@testable import PassesUICore

@Suite("ArgbColorTest")
struct ArgbColorTests {

    @Test func argbColorIsAValueClassWrappingAnInt() {
        let color = ArgbColor(argb: 0xFFEE2200)
        #expect(color.argb == 0xFFEE2200)
    }

    @Test func decodesChannelsFromArgb() {
        let color = ArgbColor(argb: 0xFF112233)
        #expect(color.alpha == 0xFF)
        #expect(color.red == 0x11)
        #expect(color.green == 0x22)
        #expect(color.blue == 0x33)
    }

    @Test func zeroIsFullyTransparentBlack() {
        let color = ArgbColor(argb: 0x00000000)
        #expect(color.alpha == 0x00)
        #expect(color.red == 0x00)
        #expect(color.green == 0x00)
        #expect(color.blue == 0x00)
    }

    @Test func maxIsOpaqueWhite() {
        let color = ArgbColor(argb: 0xFFFFFFFF)
        #expect(color.alpha == 0xFF)
        #expect(color.red == 0xFF)
        #expect(color.green == 0xFF)
        #expect(color.blue == 0xFF)
    }

    @Test func equalityIsByArgbValue() {
        #expect(ArgbColor(argb: 0xDEADBEEF) == ArgbColor(argb: 0xDEADBEEF))
        #expect(ArgbColor(argb: 0xDEADBEEF) != ArgbColor(argb: 0xDEADBEE0))
    }
}
