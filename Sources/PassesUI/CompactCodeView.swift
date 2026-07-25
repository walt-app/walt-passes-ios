import PassesCore
import PassesUICore
import SwiftUI

/// Row-scale code render for wallet-list card faces (ipass-65p.1; consumer epic
/// ios-te9). Where `ScannableCardView` enforces gate-distance minimum sizes for
/// the detail surface, this surface renders the same `(payload, format)` pair
/// compactly — the redesign's neutral list cards show a scannable's ACTUAL code
/// on the card face (a ~66 pt QR tile, or a full-width 1D band), so the code is
/// usable at a reader straight from the list.
///
/// The blessed-path guarantees, so consumers do not hand-roll them per card face:
///
///  - **White backing, both themes.** The backing is literally `Color.white`,
///    never a theme surface token, so the code scans in dark mode (spec board:
///    "barcode tiles/thumbnails stay light"). Consumers clip the outer shape;
///    the backing itself is not optional.
///  - **Quiet zones.** The fixed white inner padding guarantees a visible quiet
///    zone even when the consumer's tile hugs the code.
///  - **Sharp modules.** Nearest-neighbor upscale (`interpolation(.none)`),
///    matching `ScannableCardView`. QR paints aspect-fit (square, no
///    distortion); Code 128 fills the padded bounds because its raster is one
///    module tall and carries no data on the vertical axis.
///
/// Sizing is the caller's: frame the view externally (the small minimum floor
/// only guards against a collapsed, unscannable render). Encoder failures — and
/// the symbologies `BarcodeRenderer` cannot encode natively (EAN-13, UPC-A,
/// Code 39; ADR `passes-ui-2`) — render as a same-sized white tile with a
/// VoiceOver-readable "Barcode failed to render" label instead of throwing or
/// painting the detail surfaces' grey placeholder: a list face must never show
/// a grey blob that could be mistaken for a real code. Encoding runs in body,
/// the same trade `BarcodeView` and `ScannableCardView` make; a consumer
/// observing jank on pathological lists owns the async wrapping.
///
/// ## Trust posture
///
/// This is mechanism, not chrome: no label, no eyebrow, no trust caption, no
/// signature affordance can be composed here. The C1/C2 list-surface
/// distinctions (class eyebrow, neutral card surface — see
/// `SCANNABLE_CARD_THREAT_MODEL.md` and the `ScannableCardRowTile` lineage)
/// stay on the consumer's card, and kernel trust captions stay on detail
/// surfaces. C5 posture is unchanged: this path only re-renders through the
/// kernel's encoder-only `BarcodeRenderer`; it adds no decode surface.
/// `contentDescription` exists because the code is usually the card face's
/// dominant visual: the consumer passes its merged card description (or nil
/// when a parent element already carries it).
///
/// Mirror of Android's `is.walt.passes.ui.CompactCodeView` (wpass-tjc.2).
public struct CompactCodeView: View {
    let payload: String
    let format: ScannableFormat
    let contentDescription: String?

    public init(payload: String, format: ScannableFormat, contentDescription: String? = nil) {
        self.payload = payload
        self.format = format
        self.contentDescription = contentDescription
    }

    public var body: some View {
        let (minWidth, minHeight) = format.compactMinSize
        ZStack {
            compactCodeBacking
            if let cgImage = CompactCodeView.renderImage(payload: payload, format: format) {
                codeImage(cgImage)
                    .padding(quietZonePadding)
            } else {
                // Same-sized failure tile; silent blank rectangles are the worst
                // a11y failure mode. Wording matches ScannableCardView's placeholder.
                Color.clear
                    .accessibilityLabel(Text("Barcode failed to render"))
            }
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
    }

    @ViewBuilder
    private func codeImage(_ cgImage: CGImage) -> some View {
        let image = Image(decorative: cgImage, scale: 1, orientation: .up)
            .interpolation(.none)
            .resizable()
        Group {
            switch format {
            case .qr:
                image.aspectRatio(contentMode: .fit)
            case .code128, .ean13, .upcA, .code39:
                image
            }
        }
        .modifier(CompactCodeAccessibility(contentDescription: contentDescription))
    }

    /// Encoder entry for the compact path. Unlike the detail surfaces, the
    /// symbologies without a native generator return nil (failure tile), never
    /// the grey placeholder — internal so tests pin the routing.
    internal static func renderImage(payload: String, format: ScannableFormat) -> CGImage? {
        switch format {
        case .qr, .code128:
            return BarcodeRenderer.cgImage(payload: payload, format: format)
        case .ean13, .upcA, .code39:
            return nil
        }
    }
}

/// Applies the caller's merged card description, or marks the render as
/// decorative when a parent accessibility element already carries it.
private struct CompactCodeAccessibility: ViewModifier {
    let contentDescription: String?

    func body(content: Content) -> some View {
        if let contentDescription {
            content.accessibilityLabel(Text(contentDescription))
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// Literally white, never a theme surface token — the dark-mode scannability
/// guarantee. Internal (not private) so the smoke test pins the value;
/// rerouting the backing off this constant is amending the blessed-path
/// contract, not a refactor.
internal let compactCodeBacking: Color = .white

private let quietZonePadding: CGFloat = 8

extension ScannableFormat {
    /// Row-scale floors, deliberately below `ScannableCardView`'s gate-distance
    /// minimums: they only prevent a degenerate collapsed render when the
    /// caller forgets to size the tile, not a scannability promise at
    /// arbitrary sizes.
    internal var compactMinSize: (CGFloat, CGFloat) {
        switch self {
        case .qr: return (48, 48)
        case .code128, .ean13, .upcA, .code39: return (96, 32)
        }
    }
}
