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
///  - Zoom is purely view-side (a `scaleEffect` over the stored raster).
///    No share / export / print / open-with affordance (ADR 0005 D8).
///  - Pages arrive through a ``PassesPDFCore/DocumentPageSource`` of stored
///    Walt-produced rasters (ios-dts.16 render-once); the raster's 4 MP
///    import-time budget matches the ceiling this surface previously
///    requested from the live renderer, so zoom fidelity is unchanged and
///    the original bytes are never re-parsed.
public struct FullScreenDocumentView: View {
    public let doc: PDFDocument
    public let pages: any DocumentPageSource
    public let onClose: () -> Void
    public let telemetry: DocumentTelemetryGuard
    let closeButton: ((@escaping () -> Void) -> AnyView)?

    /// `closeButton` lets the host swap the close chrome (mirror of Android's
    /// `closeButton` slot, wlt-d3d); it receives the close handler and MUST wire
    /// it — the slot changes chrome only, never whether the surface can close.
    /// nil keeps the kernel default.
    public init(
        doc: PDFDocument,
        pages: any DocumentPageSource,
        onClose: @escaping () -> Void,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        closeButton: ((@escaping () -> Void) -> AnyView)? = nil
    ) {
        self.doc = doc
        self.pages = pages
        self.onClose = onClose
        self.telemetry = telemetry
        self.closeButton = closeButton
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
            if let closeButton {
                closeButton(onClose)
            } else {
                CloseFullScreenButton(
                    label: style.closeFullScreenLabel, style: style, action: onClose
                )
                .padding(12)
            }
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
    }
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
    let pages: any DocumentPageSource
    let cache: PDFThumbnailCache
    let telemetry: DocumentTelemetryGuard

    @State private var viewModel = PDFThumbnailViewModel()
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

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
