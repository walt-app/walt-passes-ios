import Foundation
import Testing

@testable import PassesCore

@Suite("ManifestVerifier")
struct ManifestVerifierTests {

    private func entry(_ name: String, _ text: String) -> (name: String, bytes: [UInt8]) {
        (name, [UInt8](text.utf8))
    }

    @Test func validManifestPasses() {
        let pass = ("pass.json", [UInt8]("{}".utf8))
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(PkpassFixtures.sha1Hex(pass.1))\"}")
        let result = verifyManifest([pass, manifest])
        if case .ok = result { return }
        Issue.record("expected ok, got \(result)")
    }

    @Test func missingManifest() {
        let result = verifyManifest([("pass.json", [UInt8]("{}".utf8))])
        #expect(result == .failed(.missing))
    }

    @Test func invalidJsonManifest() {
        let result = verifyManifest([entry(manifestFileName, "not json")])
        #expect(result == .failed(.invalidJson))
    }

    @Test func nonStringValueIsInvalidShape() {
        let result = verifyManifest([entry(manifestFileName, "{\"pass.json\": 5}")])
        #expect(result == .failed(.invalidShape))
    }

    @Test func arrayTopLevelIsInvalidShape() {
        let result = verifyManifest([entry(manifestFileName, "[]")])
        #expect(result == .failed(.invalidShape))
    }

    @Test func selfReferentialSignatureEntry() {
        let manifest = entry(manifestFileName, "{\"signature\":\"\(String(repeating: "a", count: 40))\"}")
        #expect(verifyManifest([manifest]) == .failed(.selfReferentialEntry))
    }

    @Test func invalidHashFormat() {
        let manifest = entry(manifestFileName, "{\"pass.json\":\"xyz\"}")
        #expect(verifyManifest([manifest]) == .failed(.invalidHashFormat(entryName: "pass.json")))
    }

    @Test func missingEntry() {
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(String(repeating: "a", count: 40))\"}")
        #expect(verifyManifest([manifest]) == .failed(.missingEntry(entryName: "pass.json")))
    }

    @Test func hashMismatch() {
        let pass = ("pass.json", [UInt8]("{}".utf8))
        let wrong = String(repeating: "0", count: 40)
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(wrong)\"}")
        #expect(verifyManifest([pass, manifest]) == .failed(.hashMismatch(entryName: "pass.json")))
    }

    @Test func extraEntryRejected() {
        let pass = ("pass.json", [UInt8]("{}".utf8))
        let extra = ("icon.png", [UInt8]([1, 2, 3]))
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(PkpassFixtures.sha1Hex(pass.1))\"}")
        #expect(verifyManifest([pass, extra, manifest]) == .failed(.extraEntry(entryName: "icon.png")))
    }

    @Test func hashMismatchBeatsExtraEntry() {
        // Both a hash mismatch and a stray file present; the per-entry loop short-circuits, so
        // the mismatch (security event) wins.
        let pass = ("pass.json", [UInt8]("{}".utf8))
        let extra = ("icon.png", [UInt8]([9]))
        let wrong = String(repeating: "0", count: 40)
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(wrong)\"}")
        #expect(verifyManifest([pass, extra, manifest]) == .failed(.hashMismatch(entryName: "pass.json")))
    }

    @Test func mixedCaseHexAccepted() {
        let pass = ("pass.json", [UInt8]("{}".utf8))
        let hex = PkpassFixtures.sha1Hex(pass.1).uppercased()
        let manifest = entry(manifestFileName, "{\"pass.json\":\"\(hex)\"}")
        if case .ok = verifyManifest([pass, manifest]) { return }
        Issue.record("expected ok for uppercase hex")
    }
}
