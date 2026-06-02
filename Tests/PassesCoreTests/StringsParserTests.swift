import Foundation
import Testing

@testable import PassesCore

@Suite("StringsParser")
struct StringsParserTests {

    private func parse(_ text: String, config: ParserConfig = ParserConfig()) -> StringsResult {
        parseStrings([UInt8](text.utf8), config: config)
    }

    private func parse(_ bytes: [UInt8], config: ParserConfig = ParserConfig()) -> StringsResult {
        parseStrings(bytes, config: config)
    }

    private func ok(_ result: StringsResult) -> [String: String]? {
        if case .ok(let strings) = result { return strings.entries }
        return nil
    }

    @Test func basicEntry() {
        #expect(ok(parse("\"key\" = \"value\";"))?["key"] == "value")
    }

    @Test func multipleEntriesAndWhitespace() {
        let text = """
            "a" = "1";
            "b" = "2";
            """
        let entries = ok(parse(text))
        #expect(entries?["a"] == "1")
        #expect(entries?["b"] == "2")
    }

    @Test func lineAndBlockComments() {
        let text = """
            // line comment
            "a" = "1"; /* block */ "b" = "2";
            """
        let entries = ok(parse(text))
        #expect(entries?.count == 2)
    }

    @Test func escapeSequences() {
        let entries = ok(parse(#""k" = "line1\nline2\t\"quoted\"";"#))
        #expect(entries?["k"] == "line1\nline2\t\"quoted\"")
    }

    @Test func unicodeBmpEscape() {
        let entries = ok(parse(#""k" = "\U0041";"#))
        #expect(entries?["k"] == "A")
    }

    @Test func surrogatePairEscape() {
        // U+1F600 grinning face = high D83D, low DE00.
        let entries = ok(parse(#""k" = "\UD83D\UDE00";"#))
        #expect(entries?["k"] == "\u{1F600}")
    }

    @Test func loneHighSurrogateIsBadEscape() {
        #expect(parse(#""k" = "\UD83D";"#) == .failed(.badEscape))
    }

    @Test func loneLowSurrogateIsBadEscape() {
        #expect(parse(#""k" = "\UDE00";"#) == .failed(.badEscape))
    }

    @Test func unterminatedStringFails() {
        #expect(parse("\"k\" = \"value;") == .failed(.unterminatedString))
    }

    @Test func unterminatedBlockCommentFails() {
        #expect(parse("/* never closed") == .failed(.unterminatedComment))
    }

    @Test func missingEqualsFails() {
        #expect(parse("\"k\" \"v\";") == .failed(.badStructure))
    }

    @Test func missingSemicolonFails() {
        #expect(parse("\"k\" = \"v\"") == .failed(.badStructure))
    }

    @Test func unknownEscapeFails() {
        #expect(parse(#""k" = "\x";"#) == .failed(.badEscape))
    }

    @Test func valueByteCapTrips() {
        let config = ParserConfig(maxJsonStringBytes: 3)
        #expect(parse("\"k\" = \"toolong\";", config: config) == .failed(.valueTooLong))
    }

    @Test func keyCapNotApplied() {
        // A long key with a short value passes even under a tiny cap (cap is value-only).
        let config = ParserConfig(maxJsonStringBytes: 3)
        let longKey = String(repeating: "k", count: 50)
        #expect(ok(parse("\"\(longKey)\" = \"ab\";", config: config))?[longKey] == "ab")
    }

    @Test func invalidUtf8Fails() {
        // 0xFF is not valid UTF-8 and there is no BOM.
        #expect(parse([0x22, 0xFF, 0x22]) == .failed(.invalidEncoding))
    }

    @Test func utf16LeBomDecoded() {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in Array("\"k\" = \"v\";".utf16) {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        #expect(ok(parse(bytes))?["k"] == "v")
    }

    @Test func duplicateKeysLastWriteWins() {
        #expect(ok(parse("\"k\" = \"1\"; \"k\" = \"2\";"))?["k"] == "2")
    }
}
