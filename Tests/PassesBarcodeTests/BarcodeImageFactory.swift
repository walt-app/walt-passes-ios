import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Test-only barcode image synthesis. Encodes a payload into a QR or Code128 symbol with
/// CoreImage's own generators, renders it to a generously upscaled PNG, and hands back the PNG
/// bytes — so a fidelity test drives the *entire* production path (``BoundedImageDecode`` +
/// Vision), not a shortcut around it.
///
/// This is the iOS counterpart to the Android corpus's `MultiFormatWriter` encode: there the
/// encoder is the same ZXing that decodes, here the encoder is CoreImage and the decoder is Vision,
/// which is exactly why the corpus must be *re-baselined* (ADR `barcode-decode-1`, Deviation 1).
enum BarcodeImageFactory {
    /// Encode `payload` as a QR symbol (byte mode, UTF-8) and return PNG bytes.
    static func qrPNG(_ payload: String, scale: CGFloat = 12) -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        return png(from: filter.outputImage, scale: scale)
    }

    /// Encode `payload` as a Code128 symbol and return PNG bytes. Code128's generator accepts only
    /// Latin-1; callers keep these payloads ASCII.
    static func code128PNG(_ payload: String, scale: CGFloat = 3) -> Data {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(payload.utf8)
        filter.quietSpace = 10
        return png(from: filter.outputImage, scale: scale)
    }

    /// Build a valid solid-white image of exactly `width` x `height` in `type` — a decodable
    /// container carrying no symbol. Doubles as a header-cap fixture (size it past the dimension
    /// limits) and, with a `type` outside the still-image roster (e.g. `.gif`), as the
    /// allowlist-rejection fixture.
    static func blank(width: Int, height: Int, type: UTType = .png) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return encode(context.makeImage()!, as: type)
    }

    /// Convenience for the common white-PNG fixture.
    static func blankPNG(width: Int, height: Int) -> Data {
        blank(width: width, height: height, type: .png)
    }

    private static func png(from ciImage: CIImage?, scale: CGFloat) -> Data {
        let scaled = ciImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        let cgImage = context.createCGImage(scaled, from: scaled.extent)!
        return encode(cgImage, as: .png)
    }

    private static func encode(_ cgImage: CGImage, as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
