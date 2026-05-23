import Foundation
import Testing

@testable import PassesCore

@Suite("ParserConfig")
struct ParserConfigTests {

    @Test func parserConfigDefaultsAreLenient() {
        let cfg = ParserConfig()
        #expect(cfg.acceptUnsignedArchives)
        #expect(cfg.acceptSelfSignedCertificates)
    }

    @Test func parserConfigStrictRejectsBoth() {
        #expect(!ParserConfig.strict.acceptUnsignedArchives)
        #expect(!ParserConfig.strict.acceptSelfSignedCertificates)
    }

    @Test func resourceLimitsAllResolveToPositiveValues() {
        let cfg = ParserConfig()
        for limit in ResourceLimit.allCases {
            #expect(limit.limitFrom(cfg) > 0, "\(limit) should resolve to a positive limit")
        }
    }

    @Test func defaultsMatchTheirNamedConstants() {
        let cfg = ParserConfig()
        #expect(cfg.maxArchiveBytes == ParserConfig.defaultMaxArchiveBytes)
        #expect(cfg.maxEntries == ParserConfig.defaultMaxEntries)
        #expect(cfg.maxEntryBytes == ParserConfig.defaultMaxEntryBytes)
        #expect(cfg.maxJsonDepth == ParserConfig.defaultMaxJsonDepth)
        #expect(cfg.maxJsonStringBytes == ParserConfig.defaultMaxJsonStringBytes)
        #expect(cfg.maxImagePixelCount == ParserConfig.defaultMaxImagePixelCount)
        #expect(cfg.maxLocaleCount == ParserConfig.defaultMaxLocaleCount)
    }
}
