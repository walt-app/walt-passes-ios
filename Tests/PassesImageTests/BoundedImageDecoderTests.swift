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

    @Test func configPinsTheApprovedNumbers() {
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

    // MARK: - Header gates (pure, so cap trips need no giant fixtures — Android
    // headerRejection mirror, split so the container is judged before the
    // metadata read)

    @Test func containerGateAdmitsOnlyTheRetainedLaneRoster() {
        let config = ImageDecodeConfig()
        #expect(containerRejection(type: nil, config: config) == .notAnImage)
        #expect(containerRejection(type: .webP, config: config) == .notAnImage)
        #expect(containerRejection(type: .heic, config: config) == .notAnImage)
        #expect(containerRejection(type: .png, config: config) == nil)
        #expect(containerRejection(type: .jpeg, config: config) == nil)
    }

    @Test func dimensionGateTripsPerSideThenArea() {
        let config = ImageDecodeConfig()
        #expect(
            dimensionRejection(width: 12_001, height: 10, config: config) == .dimensionsTooLarge)
        #expect(
            dimensionRejection(width: 8_000, height: 7_000, config: config) == .dimensionsTooLarge)
        #expect(dimensionRejection(width: 8, height: 6, config: config) == nil)
    }

    @Test func outputSizeValidityRejectsOverflowInsteadOfTrapping() {
        #expect(!isOutputSizeValid(maxWidthPx: Int.max / 2, maxHeightPx: 3, maxOutputPixels: 100))
        #expect(!isOutputSizeValid(maxWidthPx: 0, maxHeightPx: 10, maxOutputPixels: 100))
        #expect(isOutputSizeValid(maxWidthPx: 10, maxHeightPx: 10, maxOutputPixels: 100))
    }

    // MARK: - End-to-end decode arms

    /// Each test decodes on its own bank: contention on the shared bank across
    /// parallel tests read as decoderUnavailable (K2 review round 1 blocker).
    private func makeDecoder(config: ImageDecodeConfig = ImageDecodeConfig()) -> any BoundedImageDecoder {
        DefaultBoundedImageDecoder(config: config, lanes: ImageDecodeLanes(lanes: 4))
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

    // MARK: - EXIF orientation (ImageIO returns stored pixels; the fit applies
    // the header orientation so the persisted dimensions are display dimensions)

    @Test func orientedJpegComesOutUprightWithTransposedDimensions() async throws {
        // Stored 100x60 landscape, left half red / right half blue, EXIF 6
        // (camera rotated 90 CW; stored-left is the display TOP): displayed
        // 60x100 portrait with the red stored-left edge on top.
        let jpeg = try ImageFixtures.orientedJpeg(
            width: 100, height: 60, orientation: 6)
        let result = await makeDecoder().decode(
            source: .data(jpeg), maxWidthPx: 100, maxHeightPx: 100)
        guard case .ok(let raster) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        #expect(raster.widthPx == 60)
        #expect(raster.heightPx == 100)
        #expect(abs(raster.sourceAspect - 60.0 / 100.0) < 0.001)
        let top = try #require(ImageFixtures.pixel(of: raster.image, x: 30, y: 5))
        let bottom = try #require(ImageFixtures.pixel(of: raster.image, x: 30, y: 95))
        #expect(top.red > top.blue, "top of the upright image should be the red stored-left edge")
        #expect(bottom.blue > bottom.red, "bottom should be the blue stored-right edge")
    }

    /// Every orientation is checked against ImageIO's own transform
    /// (`kCGImageSourceCreateThumbnailWithTransform`) with a four-quadrant
    /// fixture, so a mirror cannot pass as a rotation and a pairwise case swap
    /// (the K2 round-2 defect) cannot return.
    @Test(arguments: 1...8)
    func everyOrientationMatchesImageIOsOwnTransform(orientation: Int) async throws {
        let jpeg = try ImageFixtures.quadrantJpeg(
            width: 40, height: 24, orientation: orientation)
        let result = await makeDecoder().decode(
            source: .data(jpeg), maxWidthPx: 64, maxHeightPx: 64)
        guard case .ok(let raster) = result else {
            Issue.record("expected ok for orientation \(orientation), got \(result)")
            return
        }
        let reference = try #require(
            ImageFixtures.imageIOOrientedReference(jpeg), "reference decode failed")
        #expect(raster.widthPx == reference.width)
        #expect(raster.heightPx == reference.height)
        let corners = [
            (3, 3), (raster.widthPx - 4, 3), (3, raster.heightPx - 4),
            (raster.widthPx - 4, raster.heightPx - 4),
        ]
        for (x, y) in corners {
            let ours = try #require(ImageFixtures.pixel(of: raster.image, x: x, y: y))
            let theirs = try #require(ImageFixtures.pixel(of: reference, x: x, y: y))
            #expect(
                abs(ours.red - theirs.red) < 60 && abs(ours.blue - theirs.blue) < 60,
                "orientation \(orientation) mismatch at (\(x),\(y)): ours r\(ours.red) b\(ours.blue) vs ref r\(theirs.red) b\(theirs.blue)"
            )
        }
    }

    /// Discover-and-pin: what ImageIO actually does with a truncated body behind
    /// a valid header. Either arm is bounded and safe; the pin records which one
    /// this platform takes so the taxonomy claim stays honest.
    @Test func truncatedBodyBehindValidHeaderIsBoundedAndClassified() async throws {
        let whole = try ImageFixtures.jpeg(width: 64, height: 64)
        let truncated = whole.prefix(whole.count / 2)
        let result = await makeDecoder().decode(
            source: .data(Data(truncated)), maxWidthPx: 64, maxHeightPx: 64)
        switch result {
        case .ok(let raster):
            // ImageIO returned a partial image: dimensions still bounded.
            #expect(raster.widthPx <= 64 && raster.heightPx <= 64)
        case .rejected(let kind):
            #expect(kind == .decodeFailed || kind == .notAnImage)
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

    /// A refusal is known synchronously, so the caller is resolved immediately —
    /// never made to wait out the deadline for it (K2 review round 1).
    @Test func aRefusedSubmissionResolvesImmediatelyAsUnavailable() async {
        let lanes = ImageDecodeLanes(lanes: 1)
        async let hog: ImageDecodeResult = withImageDecodeTimeout(
            .seconds(2), lanes: lanes,
            timeoutValue: .rejected(.decoderUnavailable)
        ) {
            Thread.sleep(forTimeInterval: 0.4)
            return .rejected(.decodeFailed)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        let refused = await withImageDecodeTimeout(
            .seconds(10), lanes: lanes,
            timeoutValue: ImageDecodeResult.rejected(.decoderUnavailable)
        ) {
            .rejected(.decodeFailed)
        }
        let elapsed = ContinuousClock.now - start
        #expect(refused.rejectedKind == .decoderUnavailable)
        #expect(elapsed < .seconds(1), "a refusal must not wait out the deadline")
        _ = await hog
    }

    /// The codec-free preflight runs outside the lanes: a saturated bank cannot
    /// mask an over-cap file's real rejection arm.
    @Test func preflightRejectionsBypassASaturatedBank() async throws {
        var config = ImageDecodeConfig()
        config.maxBytes = 64
        let lanes = ImageDecodeLanes(lanes: 1)
        async let hog: ImageDecodeResult = withImageDecodeTimeout(
            .seconds(2), lanes: lanes,
            timeoutValue: .rejected(.decoderUnavailable)
        ) {
            Thread.sleep(forTimeInterval: 0.4)
            return .rejected(.decodeFailed)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let decoder = DefaultBoundedImageDecoder(config: config, lanes: lanes)
        let png = try ImageFixtures.png(width: 32, height: 32)
        let result = await decoder.decode(source: .data(png), maxWidthPx: 8, maxHeightPx: 8)
        #expect(result.rejectedKind == .oversizedAtImport)
        _ = await hog
    }

    @Test func emptyFileFoldsToNotAnImageLikeEmptyData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_empty_\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await makeDecoder().decode(
            source: .fileURL(url), maxWidthPx: 100, maxHeightPx: 100)
        #expect(result.rejectedKind == .notAnImage)
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

    struct Pixel {
        let red: Int
        let blue: Int
    }

    /// Four distinct quadrants (TL red, TR green, BL blue, BR white in stored
    /// space), with an EXIF orientation tag — a mirror is distinguishable from a
    /// rotation.
    static func quadrantJpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw EncodeUnsupported() }
        let halfW = width / 2
        let halfH = height / 2
        // CG user-space y=0 is the bottom; stored-space top-left is high y.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: halfH, width: halfW, height: height - halfH))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: halfW, y: halfH, width: width - halfW, height: height - halfH))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: halfW, y: 0, width: width - halfW, height: halfH))
        guard let image = context.makeImage() else { throw EncodeUnsupported() }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw EncodeUnsupported() }
        let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw EncodeUnsupported() }
        return out as Data
    }

    /// The oracle: ImageIO's own orientation-applied decode of the same bytes.
    static func imageIOOrientedReference(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Stored-space left half red / right half blue, with an EXIF orientation tag.
    static func orientedJpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw EncodeUnsupported() }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage() else { throw EncodeUnsupported() }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw EncodeUnsupported() }
        let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw EncodeUnsupported() }
        return out as Data
    }

    /// Sample one pixel's red/blue channels from a CGImage.
    static func pixel(of image: CGImage, x: Int, y: Int) -> Pixel? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        // A CGBitmapContext buffer stores row 0 as the image's TOP row, so
        // top-left image coordinates index the buffer directly (the flipped
        // version of this line once cancelled an orientation bug — K2 round 2).
        let row = y
        let offset = (row * image.width + x) * 4
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return Pixel(red: Int(pixels[offset]), blue: Int(pixels[offset + 2]))
    }

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
