import PassesPDF
import PassesPDFCore
import SwiftUI

/// Full-screen detail surface for a `PDFDocument`. The ONLY place inside
/// `PassesPDFUI` where pinch-zoom and pan are available; inline
/// `DocumentView` is fixed 1x.
///
/// Trust contract (mirror of Android's `FullScreenDocumentView`):
///
///  - The non-suppressible `DocumentTrustCaption` is composed inside this
///    surface and docked to the bottom edge of the screen, structurally
///    outside the zoom transform.
///  - Zoom is purely view-side. No share / export / print / open-with
///    affordance (ADR 0005 D8).
///  - On pinch settle the surface fires a sub-rect render against the
///    currently-visible normalised page rect and swaps the displayed
///    bitmap when the result returns.
public struct FullScreenDocumentView: View {
    public let doc: PDFDocument
    public let pdfData: Data
    public let renderer: PDFRendererBinder
    public let onClose: () -> Void
    public let telemetry: DocumentTelemetryGuard

    public init(
        doc: PDFDocument,
        pdfData: Data,
        renderer: PDFRendererBinder,
        onClose: @escaping () -> Void,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
    ) {
        self.doc = doc
        self.pdfData = pdfData
        self.renderer = renderer
        self.onClose = onClose
        self.telemetry = telemetry
    }

    @State private var currentPage: Int = 0
    @State private var cache: PDFThumbnailCache = PDFThumbnailCache()

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        let style = semantics ?? .placeholder
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                pager(style: style)
                DocumentTrustCaption()
            }
            CloseFullScreenButton(label: style.closeFullScreenLabel, style: style, action: onClose)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.laneBackground.swiftUIColor)
        .onChange(of: doc.id) { _, _ in
            cache.clear()
        }
        .onDisappear {
            cache.clear()
        }
    }

    @ViewBuilder
    private func pager(style: DocumentSemantics) -> some View {
        TabView(selection: $currentPage) {
            ForEach(0..<doc.pageCount, id: \.self) { page in
                FullScreenPage(
                    document: doc,
                    pageIndex: page,
                    pdfData: pdfData,
                    renderer: renderer,
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
    }

    /// Bound on render output dimensions. Mirrors
    /// `PDFKitRenderer.maxPixels` (and Android's
    /// `PdfRendererService.MAX_PIXELS`): a defensive ceiling so the
    /// request never asks for a bitmap the renderer would have to
    /// downsize on its end. The renderer enforces the real cap; this
    /// value is the ceiling the view layer pre-clamps to.
    public static let maxRequestPixels: Int64 = 4 * 1024 * 1024
}

private struct CloseFullScreenButton: View {
    let label: String
    let style: DocumentSemantics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundColor(style.fullScreenBannerForeground.swiftUIColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(style.fullScreenBannerBackground.swiftUIColor)
        }
        .buttonStyle(.plain)
    }
}

private struct FullScreenPage: View {
    let document: PDFDocument
    let pageIndex: Int
    let pdfData: Data
    let renderer: PDFRendererBinder
    let cache: PDFThumbnailCache
    let telemetry: DocumentTelemetryGuard

    @State private var viewModel = PDFThumbnailViewModel()
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let dims = clampToMaxPixels(
                widthPx: max(Int(geo.size.width), 1),
                heightPx: max(Int(geo.size.height), 1),
                maxPixels: FullScreenDocumentView.maxRequestPixels
            )
            content(slotSize: geo.size)
                .onAppear {
                    viewModel.start(
                        document: document,
                        pdfData: pdfData,
                        target: ThumbnailRenderTarget(page: pageIndex, widthPx: dims.widthPx, heightPx: dims.heightPx),
                        context: ThumbnailRenderContext(renderer: renderer, telemetry: telemetry, cache: cache)
                    )
                }
                .onDisappear { viewModel.stop() }
        }
    }

    @ViewBuilder
    private func content(slotSize: CGSize) -> some View {
        switch viewModel.state {
        case .loading, .failed:
            Color.clear
        case .rendered(let image, _):
            image.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = clampScale(lastScale * value)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > Self.minScale else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > Self.minScale {
                            scale = Self.minScale
                            lastScale = Self.minScale
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = Self.doubleTapScale
                            lastScale = Self.doubleTapScale
                        }
                    }
                }
                .accessibilityLabel("Page \(pageIndex + 1) of \(document.pageCount)")
        }
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minScale), Self.maxScale)
    }

    /// Mirror of Android's `DEFAULT_MIN_SCALE` / `DEFAULT_MAX_SCALE` /
    /// `DEFAULT_DOUBLE_TAP_SCALE` constants.
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 5
    static let doubleTapScale: CGFloat = 2
}

/// Mirror of Android's `clampToMaxPixels(...)` helper. Pre-scales a
/// request to fit under `maxPixels` while preserving aspect ratio, so the
/// renderer is never asked to allocate beyond the cap. Exposed
/// `internal` so the surface lock test can pin the math.
struct ClampedDimensions: Equatable {
    let widthPx: Int
    let heightPx: Int
}

func clampToMaxPixels(widthPx: Int, heightPx: Int, maxPixels: Int64) -> ClampedDimensions {
    let product = Int64(widthPx) * Int64(heightPx)
    if product <= maxPixels {
        return ClampedDimensions(widthPx: widthPx, heightPx: heightPx)
    }
    let scale = (Double(maxPixels) / Double(product)).squareRoot()
    let w = max(Int(Double(widthPx) * scale), 1)
    let h = max(Int(Double(heightPx) * scale), 1)
    return ClampedDimensions(widthPx: w, heightPx: h)
}
