import CoreImage
import CoreImage.CIFilterBuiltins
import PassesCore
import SwiftUI

/// Renders a PKPASS-pass `Barcode` using CoreImage native generators. Enforces
/// a minimum on-screen size so the barcode is reliably scannable at gate
/// distance: 240 pt for QR / Aztec; 320 x 96 pt for PDF417 / Code128.
///
/// Mirror of Android's `is.walt.passes.ui.BarcodeView` (which uses ZXing on
/// JVM). See `docs/adr/passes-ui-1.md` for the CoreImage substitution.
public struct BarcodeView: View {
    let barcode: Barcode

    public init(barcode: Barcode) {
        self.barcode = barcode
    }

    public var body: some View {
        let (minWidth, minHeight): (CGFloat, CGFloat) = {
            switch barcode.format {
            case .qr, .aztec: return (240, 240)
            case .pdf417, .code128: return (320, 96)
            }
        }()
        VStack(spacing: 8) {
            if let cgImage = BarcodeRenderer.cgImage(message: barcode.message, format: barcode.format) {
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(minWidth: minWidth, minHeight: minHeight)
                    .accessibilityLabel(Text(barcode.altText ?? ""))
            } else {
                Color.clear
                    .frame(minWidth: minWidth, minHeight: minHeight)
            }
            if let alt = barcode.altText, !alt.isEmpty {
                Text(alt)
                    .font(.caption)
            }
        }
    }
}

/// CoreImage-backed renderer for both PKPASS `Barcode` and `ScannableCard`
/// payloads. The Android port uses ZXing; iOS uses Apple-native generators so
/// `walt-passes-ios` does not pick up a third-party encoder dependency. ADR
/// `passes-ui-1` documents the substitution.
internal enum BarcodeRenderer {

    static func cgImage(message: String, format: BarcodeFormat) -> CGImage? {
        let data = Data(message.utf8)
        let filter = ciFilter(for: format)
        filter?.setValue(data, forKey: "inputMessage")
        if format == .qr {
            filter?.setValue("M", forKey: "inputCorrectionLevel")
        }
        guard let ciImage = filter?.outputImage else { return nil }
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    static func cgImage(payload: String, format: ScannableFormat) -> CGImage? {
        // All five formats encode through `PassesCore.BarcodeEncoder` — the same code
        // the storage trial-encode gate runs (ADR `passes-ui-2`, revised). Failure keeps
        // its pre-gate visual: 1D degrades to the grey placeholder, QR/Code128 to nil.
        switch BarcodeEncoder.encode(payload: payload, format: format) {
        case .success(.image(let image)):
            return image
        case .success(.matrix(let matrix)):
            return cgImage(matrix: matrix)
        case .failure:
            switch format {
            case .code39, .ean13, .upcA: return placeholderCGImage()
            case .qr, .code128: return nil
            }
        }
    }

    /// Rasterize a single-row module matrix into a 1-pixel-per-module bitmap
    /// (the view scales it up with `.interpolation(.none)`, so modules stay
    /// crisp). Height is a fixed 1D bar band; the matrix carries no vertical
    /// information.
    private static let oneDBarHeightPixels = 30

    static func cgImage(matrix: BarcodeMatrix) -> CGImage? {
        let width = matrix.width
        let height = oneDBarHeightPixels
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for x in 0..<width where matrix.isSet(x: x, y: 0) {
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()
    }

    private static func ciFilter(for format: BarcodeFormat) -> CIFilter? {
        switch format {
        case .qr: return CIFilter(name: "CIQRCodeGenerator")
        case .pdf417: return CIFilter(name: "CIPDF417BarcodeGenerator")
        case .aztec: return CIFilter(name: "CIAztecCodeGenerator")
        case .code128: return CIFilter(name: "CICode128BarcodeGenerator")
        }
    }

    /// 1x1 grey CGImage so callers that hit an unsupported symbology still
    /// have a paintable image and the surface does not crash.
    private static func placeholderCGImage() -> CGImage? {
        let context = CIContext()
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        let filter = CIFilter(name: "CIConstantColorGenerator")
        filter?.setValue(CIColor(red: 0.8, green: 0.8, blue: 0.8), forKey: "inputColor")
        guard let output = filter?.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent)
    }
}
