import Foundation
import Testing

@testable import PassesUI

@Suite("PassBack link ranges")
struct PassBackLinkRangeTests {

    @Test func repeatedLinkTextIsMarkedAtEachSpansOwnOffsets() {
        let text = "https://a.example/evil\nhttps://a.example"
        let linked = linkedRuns(text)
        #expect(linked == [("https://a.example/evil", 0), ("https://a.example", 1)].map(LinkedRun.init))
    }

    @Test func phoneRepeatedInsideAUrlLinksOnlyItsOwnLine() {
        let text = "https://evil.example/555-123-4567\nCall 555-123-4567"
        let linked = linkedRuns(text)
        #expect(
            linked == [("https://evil.example/555-123-4567", 0), ("555-123-4567", 1)].map(LinkedRun.init)
        )
    }

    private struct LinkedRun: Equatable {
        let text: String
        let index: Int
        init(_ pair: (String, Int)) { (text, index) = pair }
    }

    private func linkedRuns(_ text: String) -> [LinkedRun] {
        let spans = FieldLinkScanner.scan(text, source: linkScannerTestSource)
        let attributed = backFieldAttributedValue(text, spans: spans)
        return attributed.runs.compactMap { run in
            guard let link = run.link, let index = Int(link.host ?? "") else { return nil }
            return LinkedRun((String(attributed[run.range].characters), index))
        }
    }
}
