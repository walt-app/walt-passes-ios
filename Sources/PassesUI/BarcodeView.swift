import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import PassesCore

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
        // 1D symbologies that Apple ships generators for: Code128. EAN-13,
        // UPC-A, and Code39 have no first-party CoreImage filter; render as a
        // grey placeholder rectangle so the surface composes without crashing.
        // See `docs/adr/passes-ui-2.md`.
        let data = Data(payload.utf8)
        switch format {
        case .qr:
            let filter = CIFilter(name: "CIQRCodeGenerator")
            filter?.setValue(data, forKey: "inputMessage")
            filter?.setValue("M", forKey: "inputCorrectionLevel")
            return filter?.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        case .code128:
            let filter = CIFilter(name: "CICode128BarcodeGenerator")
            filter?.setValue(data, forKey: "inputMessage")
            return filter?.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        case .code39, .ean13, .upcA:
            // No first-party generator; surface a placeholder so the call
            // site composes. Real rendering is the implementation bead's
            // follow-up (likely a hand-rolled 1D writer).
            return placeholderCGImage()
        }
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
