import SwiftUI
import PassesCore

/// Renders a `ScannableCard`'s barcode as a 1-bit-per-module raster using a
/// CoreImage generator where available; for symbologies Apple does not ship a
/// first-party generator for (EAN-13, UPC-A, Code39), the renderer surfaces a
/// neutral grey placeholder so the surface composes without crashing - see
/// `docs/adr/passes-ui-2.md`.
///
/// Minimum on-screen sizes mirror `BarcodeView` so both barcode surfaces stay
/// consistent at gate distance: 240 pt square for QR, 320 x 96 pt for the four
/// 1D symbologies.
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardView`.
public struct ScannableCardView: View {
    let card: ScannableCard

    public init(card: ScannableCard) {
        self.card = card
    }

    public var body: some View {
        let (minWidth, minHeight) = card.format.minRenderSize
        Group {
            if let cgImage = BarcodeRenderer.cgImage(payload: card.payload, format: card.format) {
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: card.format.contentMode)
                    .frame(minWidth: minWidth, minHeight: minHeight)
                    .accessibilityLabel(Text(card.label))
            } else {
                Color.clear
                    .frame(minWidth: minWidth, minHeight: minHeight)
                    .accessibilityLabel(Text("Barcode failed to render"))
            }
        }
    }
}

extension ScannableFormat {
    var minRenderSize: (CGFloat, CGFloat) {
        switch self {
        case .qr: return (240, 240)
        case .code128, .ean13, .upcA, .code39: return (320, 96)
        }
    }

    var contentMode: ContentMode {
        switch self {
        case .qr: return .fit
        case .code128, .ean13, .upcA, .code39: return .fill
        }
    }
}
