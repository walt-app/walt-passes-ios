import Testing

@testable import PassesUICore

@Suite("ArgbColor scaffold")
struct ArgbColorTests {

    @Test func decodesChannelsFromArgb() {
        let color = ArgbColor(argb: 0xFF112233)
        #expect(color.alpha == 0xFF)
        #expect(color.red == 0x11)
        #expect(color.green == 0x22)
        #expect(color.blue == 0x33)
    }
}
