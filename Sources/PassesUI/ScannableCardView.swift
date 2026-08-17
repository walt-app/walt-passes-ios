import PassesCore
import PassesUICore
import SwiftUI

/// Renders a `ScannableCard`'s barcode as a 1-bit-per-module raster through
/// `PassesCore.BarcodeEncoder` (ADR `passes-ui-2`, revised). A structurally
/// invalid 1D payload degrades to the grey placeholder so the surface still
/// composes.
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
        VStack(spacing: 12) {
            // With the caption on, hide the rendered image from VoiceOver so the
            // payload caption (the announce-worthy fallback) is not double-announced.
            ScannableCodeImage(
                card: card,
                imageDescription: showPayloadCaption ? nil : card.label
            )
            if showPayloadCaption {
                Text(isolated(card.payload))
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The code raster with its failure placeholder, shared by `ScannableCardView`
/// and the tinted `ScannableCardScreen` card (mirror of Android's
/// `ScannableCodeImage`). `imageDescription: nil` hides the RENDERED image only
/// — the caller's own texts announce the card; the failure arm always keeps its
/// label, because hiding it would leave a silent blank rectangle, the worst
/// a11y failure mode.
struct ScannableCodeImage: View {
    let card: ScannableCard
    let imageDescription: String?

    var body: some View {
        let (minWidth, minHeight) = card.format.minRenderSize
        Group {
            if let cgImage = BarcodeRenderer.cgImage(payload: card.payload, format: card.format) {
                if let imageDescription {
                    codeImage(cgImage).accessibilityLabel(Text(imageDescription))
                } else {
                    codeImage(cgImage).accessibilityHidden(true)
                }
            } else {
                Color.clear
                    .frame(minWidth: minWidth, minHeight: minHeight)
                    .accessibilityLabel(Text("Barcode failed to render"))
            }
        }
    }

    /// Applies the format's render policy. 1D symbols are stretched to the
    /// available width at a fixed bar height rather than aspect-scaled: their
    /// bars carry no vertical information, and preserving the raster's aspect
    /// either overflows the viewport (`.fill`, ipass-… / ios-ra9) or collapses
    /// the bars below scanning height (`.fit`). Same treatment `CompactCodeView`
    /// already uses on the list surface.
    @ViewBuilder
    private func codeImage(_ cgImage: CGImage) -> some View {
        let image = Image(decorative: cgImage, scale: 1, orientation: .up)
            .interpolation(.none)
            .resizable()
        switch card.format.renderPolicy {
        case .fitSquare(let minSide):
            image
                .aspectRatio(contentMode: .fit)
                .frame(minWidth: minSide, minHeight: minSide)
        case .stretchToWidth(let barHeight):
            image
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
        case .fitToWidth(let minHeight):
            image
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
        }
    }
}

/// How a symbology's raster is sized on the detail surfaces.
enum CodeRenderPolicy: Equatable {
    /// Square symbol: preserve aspect, never smaller than `minSide`.
    case fitSquare(minSide: CGFloat)
    /// 1D symbol: fill the available width, fixed `barHeight`. Never wider
    /// than its parent, so the surrounding layout cannot be dragged
    /// off-screen (ios-ra9).
    case stretchToWidth(barHeight: CGFloat)
    /// Wide 2D symbol (stacked rows — PDF417): preserve aspect since data
    /// rides both axes, bounded by the parent width (the ios-ra9 rule),
    /// letterboxing down to at least `minHeight`. Floor derived from the
    /// writer's measured output at the pinned EC (2.7-3.5:1 across the
    /// payload range): 320 wide yields 91-117 natural height, so the 90
    /// floor never distorts and only guards a degenerate parent. Inside
    /// `ScannableCardTile`'s hard 132 x 40 frame the floor over-reports
    /// height, exactly as the 1D formats' fixed bar band already does in
    /// that slot — the tile inherits, not worsens, that behavior.
    case fitToWidth(minHeight: CGFloat)
}

extension ScannableFormat {
    /// Derived from `minRenderSize` so the pinned gate-distance numbers stay
    /// the single source of truth.
    var renderPolicy: CodeRenderPolicy {
        switch self {
        case .qr, .aztec: return .fitSquare(minSide: minRenderSize.0)
        case .code128, .ean13, .upcA, .code39:
            return .stretchToWidth(barHeight: minRenderSize.1)
        case .pdf417: return .fitToWidth(minHeight: minRenderSize.1)
        }
    }

    var minRenderSize: (CGFloat, CGFloat) {
        switch self {
        // Square 2D symbols share the QR gate-distance floor. PDF417's height floor
        // follows the writer's measured aspect (see `fitToWidth`), not the 1D bar band.
        case .qr, .aztec: return (240, 240)
        case .code128, .ean13, .upcA, .code39: return (320, 96)
        case .pdf417: return (320, 90)
        }
    }

}
