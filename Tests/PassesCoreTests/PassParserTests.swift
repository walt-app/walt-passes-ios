import Foundation
import Testing

@testable import PassesCore

/// Surface-only smoke test. The production implementation (`DefaultPassParser` on Android,
/// pending on iOS) pulls a JSON tokenizer + PKCS#7 verifier; full pipeline tests land with
/// that bead. This suite pins the public protocol shape and the `PassSource` arms.
@Suite("PassParser")
struct PassParserTests {

    private struct UnsupportedStub: PassParser {
        func parse(source: PassSource) -> ParseResult {
            .unsupported(reason: .formatVersion(version: 99))
        }
    }

    @Test func protocolAcceptsByteSource() {
        let parser = UnsupportedStub()
        let result = parser.parse(source: .bytes(Data([0x50, 0x4B])))
        if case .unsupported = result { return }
        Issue.record("expected .unsupported, got \(result)")
    }

    @Test func protocolAcceptsStreamSource() {
        let parser = UnsupportedStub()
        let stream = InputStream(data: Data([0x50, 0x4B]))
        let result = parser.parse(source: .stream(stream, sizeHintBytes: 2))
        if case .unsupported = result { return }
        Issue.record("expected .unsupported, got \(result)")
    }
}
