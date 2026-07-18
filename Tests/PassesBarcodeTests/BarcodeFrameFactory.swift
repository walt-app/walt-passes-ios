import CoreGraphics
import CoreVideo
import Foundation

/// Test-only camera-frame synthesis. Renders a barcode/QR symbol into a `32BGRA` `CVPixelBuffer` —
/// the same pixel-buffer shape the app pulls off its capture output and hands to
/// ``VisionBarcodeFrameDecoder`` — so a frame test drives the *entire* production path
/// (`VNImageRequestHandler(cvPixelBuffer:)` + the shared Vision symbol decode), not a shortcut.
///
/// Symbols come from ``BarcodeImageFactory``'s `CGImage` producers, so the still-image and live-
/// frame suites decode the *same* rendered symbol through their two entry points — any divergence
/// is the entry point, not the fixture. A frame carries no compressed container (it is already-
/// decoded pixels), which is exactly why the live path skips the bounded-decode gates.
enum BarcodeFrameFactory {
    /// A `CVPixelBuffer` carrying `payload` as a QR symbol.
    static func qrFrame(_ payload: String) -> CVPixelBuffer {
        pixelBuffer(from: BarcodeImageFactory.qrCGImage(payload))
    }

    /// A `CVPixelBuffer` carrying `payload` as a Code128 symbol.
    static func code128Frame(_ payload: String) -> CVPixelBuffer {
        pixelBuffer(from: BarcodeImageFactory.code128CGImage(payload))
    }

    /// A solid-white `CVPixelBuffer` of exactly `width` x `height` — a valid frame carrying no
    /// symbol (the ``BarcodeDecodeResult/noBarcodeFound`` fixture).
    static func blankFrame(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = makeBuffer(width: width, height: height)
        draw(into: buffer) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// Blit `cgImage` into a same-size `32BGRA` pixel buffer, white-filled first so the symbol keeps
    /// its quiet zone against a clean background.
    static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer {
        let buffer = makeBuffer(width: cgImage.width, height: cgImage.height)
        draw(into: buffer) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return buffer
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer
        )
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        return buffer!
    }

    private static func draw(into buffer: CVPixelBuffer, _ body: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            // 32BGRA == little-endian 32-bit with premultiplied-first (alpha) ordering.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        body(context)
    }
}
