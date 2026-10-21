import Foundation
import Testing

@testable import PassesCore

/// End-to-end pipeline tests for the production `DefaultPassParser`. The internal slices have
/// their own focused suites; this suite pins the glue and the public `ParseResult` arms.
@Suite("PassParser")
struct PassParserTests {

    private func parse(_ archive: [UInt8], config: ParserConfig = ParserConfig()) -> ParseResult {
        let parser = PassParserFactory.create(config: config)
        return parser.parse(source: .bytes(Data(archive)))
    }

    @Test func unsignedValidArchiveParsesAsUnsigned() {
        let payload = [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let result = parse(archive)
        guard case .success(let pass, let status) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(status == .unsigned)
        #expect(pass.type == .generic)
        #expect(pass.serialNumber == "ABC123")
        #expect(pass.organizationName == "Walt")
    }

    @Test func streamSourceParsesIdenticallyToBytes() {
        let payload = [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let parser = PassParserFactory.create()
        let stream = InputStream(data: Data(archive))
        let result = parser.parse(source: .stream(stream, sizeHintBytes: Int64(archive.count)))
        if case .success = result { return }
        Issue.record("expected success, got \(result)")
    }

    @Test func unsignedRejectedInStrictMode() {
        let payload = [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let result = parse(archive, config: .strict)
        #expect(result == .tampered(reason: .signatureCryptoFailure))
    }

    @Test func garbageInputIsNotAZip() {
        let result = parse([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        #expect(result == .malformed(reason: .notAZipArchive))
    }

    @Test func emptyZipMissesManifest() {
        let result = parse(ZipBuilder.empty())
        #expect(result == .malformed(reason: .missingManifest))
    }

    @Test func missingPassJsonSurfacesMissingPassJson() {
        // Manifest present (over an icon) but no pass.json.
        let icon = ZipBuilder.File("icon.png", pngBytes(width: 1, height: 1))
        let archive = PkpassFixtures.unsignedArchive(payload: [icon])
        let result = parse(archive)
        #expect(result == .malformed(reason: .missingPassJson))
    }

    @Test func tamperedFileHashSurfacesTampered() {
        // Build a valid manifest, then swap pass.json bytes so its hash no longer matches.
        let realPass = ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())
        let manifestBytes = PkpassFixtures.manifest(for: [realPass])
        let tamperedPass = ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson(style: "coupon"))
        let archive = ZipBuilder.build([tamperedPass, ZipBuilder.File(manifestFileName, manifestBytes)])
        let result = parse(archive)
        #expect(result == .tampered(reason: .fileHashMismatch))
    }

    @Test func unknownFormatVersionUnsupported() {
        let json = #"{"formatVersion":2,"serialNumber":"s","description":"d","organizationName":"o","generic":{}}"#
        let pass = ZipBuilder.File(passJsonFileName, json)
        let archive = PkpassFixtures.unsignedArchive(payload: [pass])
        let result = parse(archive)
        #expect(result == .unsupported(reason: .formatVersion(version: 2)))
    }

    @Test func localizedStringsAttachedToPass() {
        let payload = [
            ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson()),
            ZipBuilder.File("en.lproj/pass.strings", "\"k\" = \"Hello\";"),
        ]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let result = parse(archive)
        guard case .success(let pass, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(pass.locales[PassLocale("en")]?.entries["k"] == "Hello")
    }

    // MARK: Locale drop (Android #275)

    private func passWithStrings(_ strings: [(locale: String, bytes: [UInt8])]) -> [UInt8] {
        var payload = [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())]
        payload += strings.map { ZipBuilder.File("\($0.locale).lproj/pass.strings", $0.bytes) }
        return PkpassFixtures.unsignedArchive(payload: payload)
    }

    private func locales(_ result: ParseResult) -> [PassLocale: LocalizedStrings]? {
        guard case .success(let pass, _) = result else {
            Issue.record("expected success, got \(result)")
            return nil
        }
        return pass.locales
    }

    private let goodStrings = [UInt8]("\"k\" = \"Hello\";".utf8)
    private let unparseableStrings = [UInt8]("\"k\" = ".utf8)
    /// A lone continuation byte with no BOM: not UTF-8, so strict decode refuses it.
    private let undecodableStrings: [UInt8] = [0x22, 0x6B, 0x22, 0x3D, 0x22, 0x80, 0x22, 0x3B]

    @Test func unparseableLocaleIsDroppedAndTheOthersKept() {
        let result = parse(passWithStrings([("en", goodStrings), ("fr", unparseableStrings)]))
        let map = locales(result)
        #expect(map?[PassLocale("en")]?.entries["k"] == "Hello")
        #expect(map?[PassLocale("fr")] == nil)
        #expect(map?.count == 1)
    }

    @Test func undecodableLocaleIsDroppedToo() {
        let result = parse(passWithStrings([("de", undecodableStrings), ("en", goodStrings)]))
        let map = locales(result)
        #expect(map?.keys.map(\.tag) == ["en"])
    }

    @Test func passWithEveryLocaleBadStillParsesWithNoLocales() {
        let result = parse(passWithStrings([("de", undecodableStrings), ("fr", unparseableStrings)]))
        #expect(locales(result)?.isEmpty == true)
    }

    /// The value cap is a resource limit, so it still fails the whole pass.
    @Test func oversizedStringsValueStillFailsThePass() {
        let long = [UInt8]("\"k\" = \"\(String(repeating: "x", count: 40))\";".utf8)
        let result = parse(passWithStrings([("en", long)]), config: ParserConfig(maxJsonStringBytes: 20))
        #expect(result == .malformed(reason: .resourceLimitExceeded(limit: .jsonStringSize)))
    }

    @Test func oversizedValueFailsThePassEvenAlongsideADroppedLocale() {
        let long = [UInt8]("\"k\" = \"\(String(repeating: "x", count: 40))\";".utf8)
        let archive = passWithStrings([("de", unparseableStrings), ("en", long)])
        let result = parse(archive, config: ParserConfig(maxJsonStringBytes: 20))
        #expect(result == .malformed(reason: .resourceLimitExceeded(limit: .jsonStringSize)))
    }

    /// Integrity runs over every entry before any `.strings` parse, so a swapped file is still
    /// tampering even though its content would only have dropped a locale.
    @Test func tamperedStringsFileStillFailsIntegrity() {
        let pass = ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())
        let original = ZipBuilder.File("en.lproj/pass.strings", goodStrings)
        let manifestBytes = PkpassFixtures.manifest(for: [pass, original])
        let archive = ZipBuilder.build([
            pass,
            ZipBuilder.File("en.lproj/pass.strings", unparseableStrings),
            ZipBuilder.File(manifestFileName, manifestBytes),
        ])
        #expect(parse(archive) == .tampered(reason: .fileHashMismatch))
    }

    // MARK: Inflated-size cap (Android #269)

    @Test func manySmallerEntriesTripTheInflatedSizeLimit() {
        let icons = (0..<4).map { ZipBuilder.File("icon\($0).png", [UInt8](repeating: 1, count: 300)) }
        let archive = PkpassFixtures.unsignedArchive(
            payload: [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())] + icons)
        let result = parse(archive, config: ParserConfig(maxInflatedBytes: 1_000))
        #expect(result == .malformed(reason: .resourceLimitExceeded(limit: .inflatedSize)))
    }

    @Test func imageAttachedToPass() {
        let payload = [
            ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson()),
            ZipBuilder.File("icon.png", pngBytes(width: 4, height: 4)),
        ]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let result = parse(archive)
        guard case .success(let pass, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(pass.images[.icon] != nil)
    }

    @Test func appleVerifiedWhenChainReachesBundledRoot() throws {
        // Cannot reach the real Apple root (its key is unavailable), so drive the test seam: a
        // synthesized root acts as the trust anchor and the signed manifest verifies against it.
        let root = try SignatureTestSupport.makeRoot(commonName: "Test Root")
        let leaf = try SignatureTestSupport.makeLeaf(commonName: "Test Leaf", issuer: root)
        let payload = [ZipBuilder.File(passJsonFileName, PkpassFixtures.passJson())]
        let manifestBytes = PkpassFixtures.manifest(for: payload)
        let signature = try SignatureTestSupport.sign(manifestBytes: manifestBytes, signer: leaf)
        let result = SignatureTestSupport.verify(
            signatureBytes: signature,
            manifestBytes: manifestBytes,
            config: ParserConfig(),
            trustAnchors: [root.certificate],
            knownIntermediates: []
        )
        #expect(result == .ok(.appleVerified))
    }
}

/// A minimal valid PNG: 8-byte signature + IHDR chunk declaring the given dimensions. The IHDR
/// payload is enough for `readPngDimensions`; CRC and remaining chunks are omitted (the reader
/// only inspects the IHDR header bytes).
func pngBytes(width: UInt32, height: UInt32) -> [UInt8] {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes += [0x00, 0x00, 0x00, 0x0D]  // IHDR length
    bytes += [0x49, 0x48, 0x44, 0x52]  // "IHDR"
    bytes += beU32(width)
    bytes += beU32(height)
    bytes += [0x08, 0x06, 0x00, 0x00, 0x00]  // bit depth, color type, etc.
    return bytes
}

private func beU32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}
