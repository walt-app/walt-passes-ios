import PassesCore
import PassesUICore
import SwiftUI

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
/// When `showPayloadCaption` is true the encoded payload is rendered as a monospace,
/// user-selectable caption beneath the barcode — a fallback for when a point-of-sale
/// scanner cannot read the code (GH #102). The caption is FSI/PDI isolated as
/// defense-in-depth on top of the create-boundary control-char rejection. Default false;
/// only `ScannableCardScreen` opts in (tile / row registers are identification-sized).
///
/// Mirror of Android's `is.walt.passes.ui.ScannableCardView`.
public struct ScannableCardView: View {
    let card: ScannableCard
    let showPayloadCaption: Bool

    public init(card: ScannableCard, showPayloadCaption: Bool = false) {
        self.card = card
        self.showPayloadCaption = showPayloadCaption
    }

    public var body: some View {
        let (minWidth, minHeight) = card.format.minRenderSize
        VStack(spacing: 12) {
            Group {
                if let cgImage = BarcodeRenderer.cgImage(payload: card.payload, format: card.format) {
                    Image(decorative: cgImage, scale: 1, orientation: .up)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: card.format.contentMode)
                        .frame(minWidth: minWidth, minHeight: minHeight)
                        .accessibilityLabel(Text(card.label))
                        // With the caption on, hide the image from VoiceOver so the payload
                        // caption (the announce-worthy fallback) is not double-announced.
                        .accessibilityHidden(showPayloadCaption)
                } else {
                    Color.clear
                        .frame(minWidth: minWidth, minHeight: minHeight)
                        .accessibilityLabel(Text("Barcode failed to render"))
                }
            }
            if showPayloadCaption {
                Text(isolated(card.payload))
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
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
