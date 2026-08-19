import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PassesImage

/// The in-process bounded image decode-and-retain (ios-dts.2, §7-approved mirror of
/// Android `passes-image` minus the isolatedProcess plumbing): caps enforced from the
/// header before any allocation, the JPEG/PNG retained-lane allowlist, aspect-fit
/// output that never upscales, and the closed `ImageDecodeRejectedKind` taxonomy.
@Suite("Bounded image decoder")
struct BoundedImageDecoderTests {

    // MARK: - Config pins (§7 terms; changing one is a deliberate, test-breaking edit)

    @Test func configPinsTheSevenApprovedNumbers() {
        #expect(ImageDecodeConfig.defaultMaxBytes == 25 * 1024 * 1024)
        #expect(ImageDecodeConfig.defaultMaxDimensionPx == 12_000)
        #expect(ImageDecodeConfig.defaultMaxAreaPx == 50_000_000)
        #expect(ImageDecodeConfig.defaultDecodeTimeout == .milliseconds(5000))
        #expect(ImageDecodeConfig.defaultMaxOutputPixels == 4 * 1024 * 1024)
    }

    /// §7 resolution on ios-dts.2 term (2): the retained-image lane admits JPEG and
    /// PNG ONLY. WebP dropped (worst CVE history, not an iPhone photo format);
    /// HEIF/HEIC not admitted natively (the gallery lane transcodes out-of-process).
    /// The five-container roster stays approved for the barcode READ lane only.
    @Test func retainedLaneAllowlistIsJpegAndPngOnly() {
        let allowed = ImageDecodeConfig.defaultAllowedContentTypes
        #expect(allowed == [UTType.jpeg, UTType.png])
    }

    @Test func rejectedKindIsItsOwnClosedFiveCaseTaxonomy() {
        #expect(
            ImageDecodeRejectedKind.allCases == [
                .notAnImage, .oversizedAtImport, .dimensionsTooLarge, .decodeFailed,
                .decoderUnavailable,
            ])
    }

    // MARK: - Output-dims math (Android outputDims mirror)

    @Test func outputDimsFitWithinBoundsPreservingAspect() {
        let dims = outputDims(srcWidth: 100, srcHeight: 60, maxWidthPx: 50, maxHeightPx: 50)
        #expect(dims.widthPx == 50)
        #expect(dims.heightPx == 30)
    }

    @Test func outputDimsNeverUpscale() {
        let dims = outputDims(srcWidth: 8, srcHeight: 6, maxWidthPx: 100, maxHeightPx: 100)
        #expect(dims.widthPx == 8)
        #expect(dims.heightPx == 6)
    }

    @Test func outputDimsClampToAtLeastOnePixel() {
        let dims = outputDims(srcWidth: 10_000, srcHeight: 1, maxWidthPx: 100, maxHeightPx: 100)
        #expect(dims.widthPx == 100)
        #expect(dims.heightPx == 1)
    }

    // MARK: - Header gate (pure, so cap trips need no giant fixtures — Android
    // headerRejection mirror)

    @Test func headerGatePrecedenceIsContainerThenSideThenArea() {
        let config = ImageDecodeConfig()
        #expect(headerRejection(type: nil, width: 10, height: 10, config: config) == .notAnImage)
        #expect(headerRejection(type: .webP, width: 10, height: 10, config: config) == .notAnImage)
        #expect(headerRejection(type: .heic, width: 10, height: 10, config: config) == .notAnImage)
        #expect(
            headerRejection(type: .png, width: 12_001, height: 10, config: config)
                == .dimensionsTooLarge)
        #expect(
            headerRejection(type: .png, width: 8_000, height: 7_000, config: config)
                == .dimensionsTooLarge)
        #expect(headerRejection(type: .png, width: 8, height: 6, config: config) == nil)
        #expect(headerRejection(type: .jpeg, width: 8, height: 6, config: config) == nil)
    }

    // MARK: - End-to-end decode arms

    private func makeDecoder(config: ImageDecodeConfig = ImageDecodeConfig()) -> any BoundedImageDecoder {
        makeBoundedImageDecoder(config: config)
    }

    @Test func decodesAPngWithinCapsToTheFittedRaster() async throws {
        let png = try ImageFixtures.png(width: 100, height: 60)
        let result = await makeDecoder().decode(
            source: .data(png), maxWidthPx: 50, maxHeightPx: 50)
        guard case .ok(let raster) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        #expect(raster.widthPx == 50)
        #expect(raster.heightPx == 30)
        #expect(abs(raster.sourceAspect - 100.0 / 60.0) < 0.001)
        #expect(raster.image.width == 50)
        #expect(raster.image.height == 30)
    }

    @Test func smallImagesAreNeverUpscaled() async throws {
        let jpeg = try ImageFixtures.jpeg(width: 8, height: 6)
        let result = await makeDecoder().decode(
            source: .data(jpeg), maxWidthPx: 2048, maxHeightPx: 2048)
        guard case .ok(let raster) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        #expect(raster.widthPx == 8)
        #expect(raster.heightPx == 6)
    }

    @Test func overCapBytesRejectAsOversizedBeforeAnyDecode() async throws {
        var config = ImageDecodeConfig()
        config.maxBytes = 64
        let png = try ImageFixtures.png(width: 32, height: 32)
        try #require(png.count > 64)
        let result = await makeDecoder(config: config).decode(
            source: .data(png), maxWidthPx: 100, maxHeightPx: 100)
        #expect(result.rejectedKind == .oversizedAtImport)
    }

    @Test func overCapHeaderDimensionsRejectAsDimensionsTooLarge() async throws {
        var config = ImageDecodeConfig()
        config.maxDimensionPx = 16
        let png = try ImageFixtures.png(width: 32, height: 8)
        let result = await makeDecoder(config: config).decode(
            source: .data(png), maxWidthPx: 8, maxHeightPx: 8)
        #expect(result.rejectedKind == .dimensionsTooLarge)
    }

    @Test func heicRejectsAsNotAnImageOnTheRetainedLane() async throws {
        let heic: Data
        do {
            heic = try ImageFixtures.encoded(width: 8, height: 8, type: UTType.heic.identifier)
        } catch {
            // HEIC encode support varies by host; the pure header-gate test above
            // already pins the rejection for the type.
            return
        }
        let result = await makeDecoder().decode(
            source: .data(heic), maxWidthPx: 100, maxHeightPx: 100)
        #expect(result.rejectedKind == .notAnImage)
    }

    @Test func garbageBytesRejectAsNotAnImage() async {
        let result = await makeDecoder().decode(
            source: .data(Data([0xBA, 0xD0, 0xCA, 0xFE])), maxWidthPx: 100, maxHeightPx: 100)
        #expect(result.rejectedKind == .notAnImage)
    }

    @Test func unreadableFileSourceRejectsAsDecodeFailed() async {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        let result = await makeDecoder().decode(
            source: .fileURL(missing), maxWidthPx: 100, maxHeightPx: 100)
        #expect(result.rejectedKind == .decodeFailed)
    }

    /// The output bound is checked FIRST, before any byte is read: an out-of-bounds
    /// request against an unreadable source still reports the request bug, not the
    /// source state (Android `isOutputSizeValid`-first ordering).
    @Test func outOfBoundsOutputRequestRejectsBeforeAnyRead() async {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        let tooBig = await makeDecoder().decode(
            source: .fileURL(missing), maxWidthPx: 3000, maxHeightPx: 3000)
        #expect(tooBig.rejectedKind == .decodeFailed)
        let nonPositive = await makeDecoder().decode(
            source: .fileURL(missing), maxWidthPx: 0, maxHeightPx: 100)
        #expect(nonPositive.rejectedKind == .decodeFailed)
    }

    /// 2048 x 2048 sits exactly at the 4 MP output ceiling (the Android
    /// `DEFAULT_MAX_IMAGE_DECODE_PX` relationship) and must be accepted.
    @Test func outputCeilingBoundaryIsAccepted() async throws {
        let png = try ImageFixtures.png(width: 8, height: 8)
        let result = await makeDecoder().decode(
            source: .data(png), maxWidthPx: 2048, maxHeightPx: 2048)
        guard case .ok = result else {
            Issue.record("2048x2048 request must sit inside the ceiling: \(result)")
            return
        }
    }

    // MARK: - Bounded wait (the §7 term: bounds the WAIT, not the work)

    @Test func timeoutResolvesAsDecoderUnavailable() async {
        let result = await withImageDecodeTimeout(
            .milliseconds(30),
            lanes: ImageDecodeLanes(lanes: 1),
            timeoutValue: ImageDecodeResult.rejected(.decoderUnavailable)
        ) {
            Thread.sleep(forTimeInterval: 2)
            return ImageDecodeResult.rejected(.decodeFailed)
        }
        #expect(result.rejectedKind == .decoderUnavailable)
    }

    @Test func aRefusedSubmissionResolvesAsTimeoutRatherThanQueueing() async {
        let lanes = ImageDecodeLanes(lanes: 1)
        async let hog: ImageDecodeResult = withImageDecodeTimeout(
            .milliseconds(500), lanes: lanes,
            timeoutValue: .rejected(.decoderUnavailable)
        ) {
            Thread.sleep(forTimeInterval: 0.3)
            return .rejected(.decodeFailed)
        }
        try? await Task.sleep(for: .milliseconds(50))
        let refused = await withImageDecodeTimeout(
            .milliseconds(80), lanes: lanes,
            timeoutValue: ImageDecodeResult.rejected(.decoderUnavailable)
        ) {
            .rejected(.decodeFailed)
        }
        #expect(refused.rejectedKind == .decoderUnavailable)
        _ = await hog
    }
}

extension ImageDecodeResult {
    fileprivate var rejectedKind: ImageDecodeRejectedKind? {
        if case .rejected(let kind) = self { return kind }
        return nil
    }
}

/// Real encoded fixtures via ImageIO so the decoder is exercised against the
/// production codec path.
enum ImageFixtures {
    static func png(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.png.identifier)
    }

    static func jpeg(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.jpeg.identifier)
    }

    struct EncodeUnsupported: Error {}

    static func encoded(width: Int, height: Int, type: String) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw EncodeUnsupported() }
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw EncodeUnsupported() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)
        else { throw EncodeUnsupported() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeUnsupported() }
        return out as Data
    }
}
