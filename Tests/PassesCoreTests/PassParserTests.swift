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
        let payload = [ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson())]
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
        let payload = [ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson())]
        let archive = PkpassFixtures.unsignedArchive(payload: payload)
        let parser = PassParserFactory.create()
        let stream = InputStream(data: Data(archive))
        let result = parser.parse(source: .stream(stream, sizeHintBytes: Int64(archive.count)))
        if case .success = result { return }
        Issue.record("expected success, got \(result)")
    }

    @Test func unsignedRejectedInStrictMode() {
        let payload = [ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson())]
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
        let realPass = ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson())
        let manifestBytes = PkpassFixtures.manifest(for: [realPass])
        let tamperedPass = ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson(style: "coupon"))
        let archive = ZipBuilder.build([tamperedPass, ZipBuilder.File(MANIFEST_FILE_NAME, manifestBytes)])
        let result = parse(archive)
        #expect(result == .tampered(reason: .fileHashMismatch))
    }

    @Test func unknownFormatVersionUnsupported() {
        let json = #"{"formatVersion":2,"serialNumber":"s","description":"d","organizationName":"o","generic":{}}"#
        let pass = ZipBuilder.File(PASS_JSON_FILE_NAME, json)
        let archive = PkpassFixtures.unsignedArchive(payload: [pass])
        let result = parse(archive)
        #expect(result == .unsupported(reason: .formatVersion(version: 2)))
    }

    @Test func localizedStringsAttachedToPass() {
        let payload = [
            ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson()),
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

    @Test func imageAttachedToPass() {
        let payload = [
            ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson()),
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
        let payload = [ZipBuilder.File(PASS_JSON_FILE_NAME, PkpassFixtures.passJson())]
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
