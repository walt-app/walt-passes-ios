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
        case gateSaidNo
        case malformed
    }

    private func allowAll() -> BoundedDecodePolicy<TestReason> {
        BoundedDecodePolicy(
            gate: { _, _, _ in nil },
            onMalformed: { .malformed }
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

    @Test func gateSeesContainerTypeAndHeaderDimensions() throws {
        let jpeg = try TestImages.jpeg(width: 10, height: 4)
        nonisolated(unsafe) var seen: (UTType?, Int, Int)?
        let policy = BoundedDecodePolicy<TestReason>(
            gate: { type, width, height in
                seen = (type, width, height)
                return nil
            },
            onMalformed: { .malformed }
        )
        _ = decodeBounded(rawBytes: jpeg, policy: policy)
        #expect(seen?.0?.conforms(to: .jpeg) == true)
        #expect(seen?.1 == 10)
        #expect(seen?.2 == 4)
    }

    @Test func gateRejectionWinsAndNothingDecodes() throws {
        let png = try TestImages.png(width: 8, height: 8)
        let policy = BoundedDecodePolicy<TestReason>(
            gate: { _, _, _ in .gateSaidNo },
            onMalformed: { .malformed }
        )
        let outcome = decodeBounded(rawBytes: png, policy: policy)
        #expect(outcome.rejection == .gateSaidNo)
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
    static func png(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.png.identifier)
    }

    static func jpeg(width: Int, height: Int) throws -> Data {
        try encoded(width: width, height: height, type: UTType.jpeg.identifier)
    }

    static func encoded(width: Int, height: Int, type: String) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}
