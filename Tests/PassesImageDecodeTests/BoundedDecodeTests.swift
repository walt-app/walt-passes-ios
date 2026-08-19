import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PassesImageDecode

/// The shared header-gated bounded decode (mirror of Android `passes-image-decode`'s
/// `decodeBounded`, wpass-gnp): mechanism only, generic over the caller's rejection
/// type. The gate sees the container type and the HEADER dimensions before any pixel
/// materialization; a gate rejection wins and nothing is decoded; malformed bytes fold
/// to the caller's own reason.
@Suite("Bounded decode primitive")
struct BoundedDecodeTests {

    private enum TestReason: Equatable {
        case containerSaidNo
        case dimensionsSaidNo
        case malformed
        case undecodable
    }

    private func allowAll() -> BoundedDecodePolicy<TestReason> {
        BoundedDecodePolicy(
            containerGate: { _ in nil },
            dimensionGate: { _, _ in nil },
            onMalformed: { .malformed },
            onDecodeFailed: { .undecodable }
        )
    }

    @Test func decodesAPngTheGateAllows() throws {
        let png = try TestImages.png(width: 8, height: 6)
        let outcome = decodeBounded(rawBytes: png, policy: allowAll())
        guard case .decoded(let image) = outcome else {
            Issue.record("expected decode, got \(outcome)")
            return
        }
        #expect(image.width == 8)
        #expect(image.height == 6)
    }

    @Test func gatesSeeContainerTypeAndHeaderDimensions() throws {
        let jpeg = try TestImages.jpeg(width: 10, height: 4)
        nonisolated(unsafe) var seenType: UTType??
        nonisolated(unsafe) var seenDims: (Int, Int)?
        let policy = BoundedDecodePolicy<TestReason>(
            containerGate: { type in
                seenType = type
                return nil
            },
            dimensionGate: { width, height in
                seenDims = (width, height)
                return nil
            },
            onMalformed: { .malformed },
            onDecodeFailed: { .undecodable }
        )
        _ = decodeBounded(rawBytes: jpeg, policy: policy)
        #expect(seenType??.conforms(to: .jpeg) == true)
        #expect(seenDims?.0 == 10)
        #expect(seenDims?.1 == 4)
    }

    /// The container gate is judged BEFORE the header-properties read: ImageIO's
    /// metadata parser never runs over a container the allowlist rejects.
    @Test func containerRejectionWinsBeforeTheMetadataRead() throws {
        let png = try TestImages.png(width: 8, height: 8)
        nonisolated(unsafe) var dimensionGateRan = false
        let policy = BoundedDecodePolicy<TestReason>(
            containerGate: { _ in .containerSaidNo },
            dimensionGate: { _, _ in
                dimensionGateRan = true
                return nil
            },
            onMalformed: { .malformed },
            onDecodeFailed: { .undecodable }
        )
        let outcome = decodeBounded(rawBytes: png, policy: policy)
        #expect(outcome.rejection == .containerSaidNo)
        #expect(!dimensionGateRan)
    }

    @Test func dimensionRejectionWinsAndNothingDecodes() throws {
        let png = try TestImages.png(width: 8, height: 8)
        let policy = BoundedDecodePolicy<TestReason>(
            containerGate: { _ in nil },
            dimensionGate: { _, _ in .dimensionsSaidNo },
            onMalformed: { .malformed },
            onDecodeFailed: { .undecodable }
        )
        let outcome = decodeBounded(rawBytes: png, policy: policy)
        #expect(outcome.rejection == .dimensionsSaidNo)
    }

    @Test func malformedBytesFoldToTheCallersReason() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        let outcome = decodeBounded(rawBytes: garbage, policy: allowAll())
        #expect(outcome.rejection == .malformed)
    }

    @Test func emptyBytesFoldToTheCallersReason() {
        let outcome = decodeBounded(rawBytes: Data(), policy: allowAll())
        #expect(outcome.rejection == .malformed)
    }
}

extension BoundedDecodeOutcome {
    fileprivate var rejection: R? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// Real encoded fixtures via ImageIO, so the primitive is exercised against the
/// production codec path rather than hand-crafted byte strings.
enum TestImages {
    struct EncodeUnsupported: Error {}

    static func png(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.png.identifier)
    }

    static func jpeg(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.jpeg.identifier)
    }

    static func encoded(width: Int, height: Int, type: String) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw EncodeUnsupported() }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
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
