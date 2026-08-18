import PassesPDFCore
import PassesUICore
import SwiftUI

/// Presentation of a `PDFDocument` — a non-suppressible trust caption
/// above a swipeable pager of rasterised pages. `DocumentView` fills the
/// bounds the consumer gives it and does NOT assume a full screen.
///
/// Trust contract (mirror of Android's `DocumentView`):
///
///  - The non-suppressible `DocumentTrustCaption` is rendered inside this
///    view and is not gated by any parameter. No `DocumentView` overload
///    omits it. The surface-lock test pins the parameter shape; the trust
///    surface test pins the visible-text contract.
///  - The view displays only the rasterised page bitmaps and the caption.
///    ADR 0005 D4: no PDF metadata, no extracted text, no annotation
///    list, no attachment list.
///  - The view exposes no share, export, print, or open-with affordance.
///    ADR 0005 D8.
///  - Inline surface is fixed 1x: no pinch-zoom, no pan, no double-tap.
///    Zoom lives only on the full-screen detail surface
///    (`FullScreenDocumentView`).
///
/// Pages arrive through a ``PassesPDFCore/DocumentPageSource`` of stored
/// Walt-produced rasters (ios-dts.16 render-once): this module holds no PDF
/// parser and cannot re-parse the original document bytes.
///
/// `faceTint` (wpass-80y.2 mirror) is presentation only — the kernel never
/// learns why a color was chosen and stores nothing; which color an item
/// carries is the consumer's (`WalletColorRepository`, keyed per wallet entry).
/// The tint reaches the FRAME the page render sits on and nothing else: the
/// rasterised page is real content and renders identically tinted or not, and
/// identically in light and dark. The rounded card shape arrives WITH the tint
/// (paint only, never a clip), so untinted consumers keep today's flush
/// `laneBackground` frame; `nil` and a fully transparent tint both mean "no
/// tint" via the shared `faceIsTinted`. Pass an opaque color: a translucent
/// tint composites over host paint the kernel cannot see.
public struct DocumentView: View {
    public let doc: PDFDocument
    public let pages: any DocumentPageSource
    public let telemetry: DocumentTelemetryGuard
    public let onOpenFullScreen: (() -> Void)?
    public let faceTint: ArgbColor?

    public init(
        doc: PDFDocument,
        pages: any DocumentPageSource,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        onOpenFullScreen: (() -> Void)? = nil,
        faceTint: ArgbColor? = nil
    ) {
        self.doc = doc
        self.pages = pages
        self.telemetry = telemetry
        self.onOpenFullScreen = onOpenFullScreen
        self.faceTint = faceTint
    }

    @State private var currentPage: Int = 0
    @State private var cache: PDFThumbnailCache = PDFThumbnailCache()

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        let style = semantics ?? .placeholder
        VStack(spacing: 8) {
            DocumentTrustCaption()
            pager(style: style)
            if let onOpenFullScreen {
                FullScreenBanner(label: style.fullScreenBannerLabel, style: style, action: onOpenFullScreen)
            }
        }
        .onChange(of: doc.id) { _, _ in
            cache.clear()
        }
        .onDisappear {
            cache.clear()
        }
    }

    @ViewBuilder
    private func pager(style: DocumentSemantics) -> some View {
        // SwiftUI's TabView(.page) replaces Compose's HorizontalPager.
        // The pager fills the slot between the caption and the optional
        // banner; ContentScale.Fit equivalent comes from the page view's
        // `aspectRatio(contentMode: .fit)`.
        TabView(selection: $currentPage) {
            ForEach(0..<doc.pageCount, id: \.self) { page in
                DocumentPage(
                    document: doc,
                    pageIndex: page,
                    pages: pages,
                    cache: cache,
                    telemetry: telemetry
                )
                .tag(page)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(documentFace(style: style))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen?()
        }
    }

    /// The frame the page render sits on (showing through the fit letterbox
    /// bars), hoisted from the per-page background to the pager container —
    /// the same painted region, matching Android's slot placement. Background
    /// only: it never clips or filters the page, which is what makes the
    /// frame-not-content constraint structural. The rounded card shape arrives
    /// with the tint: an untinted frame is the host's own `laneBackground`
    /// tone bleeding to the slot edge, and rounding it would change every
    /// consumer already shipping the surface.
    @ViewBuilder
    private func documentFace(style: DocumentSemantics) -> some View {
        if let tint = Self.resolvedFace(faceTint) {
            RoundedRectangle(cornerRadius: Self.faceRadius)
                .fill(tint.swiftUIColor)
        } else {
            style.laneBackground.swiftUIColor
        }
    }

    /// Pure face decision routed through the shared `faceIsTinted` gate so the
    /// body cannot skip it — `nil` means "keep the flush laneBackground frame".
    /// Internal so a test pins BOTH directions (the wpass-80y.5 lesson).
    static func resolvedFace(_ faceTint: ArgbColor?) -> ArgbColor? {
        faceIsTinted(faceTint) ? faceTint : nil
    }

    /// Card radius from the 26.08.08 design's card anatomy spec. Duplicated as
    /// `cardRadius` in `PassesUI`'s `ScannableCardScreen` (the Android wpass-nbr
    /// shared-token hoist is still open there too).
    private static let faceRadius: CGFloat = 20
}

/// Docked discoverability hint below the pager. When the consumer provides
/// no `onOpenFullScreen` the banner is absent; when wired the page itself
/// is also a tap target (handled at the pager level).
private struct FullScreenBanner: View {
    let label: String
    let style: DocumentSemantics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundColor(style.fullScreenBannerForeground.swiftUIColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(style.fullScreenBannerBackground.swiftUIColor)
        }
        .buttonStyle(.plain)
    }
}

private struct DocumentPage: View {
    let document: PDFDocument
    let pageIndex: Int
    let pages: any DocumentPageSource
    let cache: PDFThumbnailCache
    let telemetry: DocumentTelemetryGuard

    @State private var viewModel = PDFThumbnailViewModel()

    var body: some View {
        content
            .onAppear {
                viewModel.start(
                    document: document,
                    page: pageIndex,
                    source: pages,
                    context: ThumbnailRenderContext(telemetry: telemetry, cache: cache)
                )
            }
            .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading, .failed:
            // Mirror of Android: loading and failed render nothing in the
            // inline surface; the pager itself is the placeholder.
            Color.clear
        case .rendered(let image, _):
            image.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel("Page \(pageIndex + 1) of \(document.pageCount)")
        }
    }

}
