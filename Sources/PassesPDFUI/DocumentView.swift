import SwiftUI
import PassesPDF
import PassesPDFCore

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
/// `pdfData` is owned by the caller. It MUST remain valid for as long as
/// `DocumentView` is visible.
public struct DocumentView: View {
    public let doc: PDFDocument
    public let pdfData: Data
    public let renderer: PDFRendererBinder
    public let telemetry: DocumentTelemetryGuard
    public let onOpenFullScreen: (() -> Void)?

    public init(
        doc: PDFDocument,
        pdfData: Data,
        renderer: PDFRendererBinder,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        onOpenFullScreen: (() -> Void)? = nil
    ) {
        self.doc = doc
        self.pdfData = pdfData
        self.renderer = renderer
        self.telemetry = telemetry
        self.onOpenFullScreen = onOpenFullScreen
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
                    pdfData: pdfData,
                    renderer: renderer,
                    cache: cache,
                    telemetry: telemetry
                )
                .tag(page)
                .background(style.laneBackground.swiftUIColor)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen?()
        }
    }
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
    let pdfData: Data
    let renderer: PDFRendererBinder
    let cache: PDFThumbnailCache
    let telemetry: DocumentTelemetryGuard

    @State private var viewModel = PDFThumbnailViewModel()

    var body: some View {
        GeometryReader { geo in
            let widthPx = max(Int(geo.size.width), 1)
            let heightPx = max(Int(geo.size.height), 1)
            content
                .onAppear {
                    viewModel.start(
                        document: document,
                        pdfData: pdfData,
                        renderer: renderer,
                        page: pageIndex,
                        targetWidthPx: max(widthPx, Self.targetPageWidthPx),
                        targetHeightPx: max(heightPx, Self.targetPageHeightPx),
                        telemetry: telemetry,
                        cache: cache
                    )
                }
                .onDisappear { viewModel.stop() }
        }
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

    /// Render budget defaults. Mirror of Android's 360 / 480 dp baseline.
    /// The actual request adopts whichever is larger between the layout
    /// slot and these constants, so a small consumer slot still gets a
    /// crisp baseline render.
    static let targetPageWidthPx: Int = 360
    static let targetPageHeightPx: Int = 480
}
