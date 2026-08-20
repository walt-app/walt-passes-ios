import PassesImage
import PassesPDFCore
import SwiftUI

/// Full-screen detail surface for a `Document` (generalized past PDF-only by
/// wpass-pl7.4's mirror, ios-dts.12). The ONLY place inside `PassesPDFUI`
/// where pinch-zoom and pan are available; inline `DocumentView` is fixed 1x.
///
/// Like `DocumentView`, a dispatcher on the sealed `Document` arm set:
/// `PDFDocument` gets a swipeable pager of zoomable stored-raster pages;
/// `ImageDocument` gets a single zoomable image over the §7 bounded decode;
/// `BarcodedImageDocument` (wpass-8lu) routes to the SAME image surface for
/// its image half — the barcode half is consumer-composed with `PassesUI`.
/// Backend handles are kind-specific and optional, exactly as on
/// `DocumentView`: `pages` for the PDF arm, the `imageSource`/`imageDecoder`
/// pair for the image arms; a missing pair fails fast.
///
/// Trust contract:
///
///  - The non-suppressible `DocumentTrustCaption` is docked to the bottom
///    edge as a SIBLING of the arm dispatch, structurally outside every
///    arm's zoom transform (ADR 0005 Z.8) — no arm can scale, translate, or
///    overdraw it (the zoom clip lives on `ZoomableContent`'s unscaled
///    ancestor; see the clip lesson there).
///  - Zoom is purely view-side. No share / export / print / open-with
///    affordance (ADR 0005 D8).
///  - PDF pixels are stored Walt-produced rasters (render-once, ios-dts.16);
///    image pixels come only from the caller-supplied bounded decoder.
public struct FullScreenDocumentView: View {
    public let doc: any Document
    public let pages: (any DocumentPageSource)?
    public let imageSource: ImageDecodeSource?
    public let imageDecoder: (any BoundedImageDecoder)?
    public let onClose: () -> Void
    public let telemetry: DocumentTelemetryGuard
    let closeButton: ((@escaping () -> Void) -> AnyView)?

    /// `closeButton` lets the host swap the close chrome (mirror of Android's
    /// `closeButton` slot, wlt-d3d); it receives the close handler and MUST wire
    /// it — the slot changes chrome only, never whether the surface can close.
    /// nil keeps the kernel default.
    public init(
        doc: any Document,
        pages: (any DocumentPageSource)? = nil,
        imageSource: ImageDecodeSource? = nil,
        imageDecoder: (any BoundedImageDecoder)? = nil,
        onClose: @escaping () -> Void,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        closeButton: ((@escaping () -> Void) -> AnyView)? = nil
    ) {
        self.doc = doc
        self.pages = pages
        self.imageSource = imageSource
        self.imageDecoder = imageDecoder
        self.onClose = onClose
        self.telemetry = telemetry
        self.closeButton = closeButton
    }

    /// Longer-side cap for full-screen decodes, shared by the pager's stored-
    /// raster inflate and the image arm's bounded decode. 2048² sits exactly
    /// at the decoder's 4 MP output ceiling, so Android's slot × maxScale
    /// request collapses to this ceiling on every supported display — the
    /// pinch stays as sharp as the budget allows without a sub-rect path
    /// (the bounded decoder has none, deliberately).
    static let fullScreenMaxPixelSize: Int = 2048

    @Environment(\.documentSemantics) private var semantics

    public var body: some View {
        let style = semantics ?? .placeholder
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                arm(style: style)
                // Sibling of the arm dispatch (Z.8): outside every zoom
                // transform, and the arm's clip cannot be outdrawn onto it.
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
    }

    @ViewBuilder
    private func arm(style: DocumentSemantics) -> some View {
        switch doc {
        case let pdf as PDFDocument:
            FullScreenPdfView(
                doc: pdf,
                pages: required(pages, "FullScreenDocumentView(PDFDocument) requires pages"),
                telemetry: telemetry
            )
        case is ImageDocument, is BarcodedImageDocument:
            FullScreenImageView(
                documentId: doc.documentId,
                source: required(
                    imageSource,
                    "FullScreenDocumentView(\(type(of: doc))) requires imageSource"),
                decoder: required(
                    imageDecoder,
                    "FullScreenDocumentView(\(type(of: doc))) requires imageDecoder"),
                telemetry: telemetry
            )
        default:
            // `DocumentSealedSetTests` fails when `documentArms` grows; this
            // switch must then be reconciled BY HAND (test-time pin, as on
            // `DocumentView`).
            fatalError("FullScreenDocumentView: unknown Document arm \(type(of: doc))")
        }
    }

    private func required<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
        guard let value else { fatalError(message()) }
        return value
    }
}

/// The PDF arm: swipeable pager of zoomable stored-raster pages (render-once).
private struct FullScreenPdfView: View {
    let doc: PDFDocument
    let pages: any DocumentPageSource
    let telemetry: DocumentTelemetryGuard

    @State private var currentPage: Int = 0
    @State private var cache: PDFThumbnailCache = PDFThumbnailCache()

    var body: some View {
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
        .onChange(of: doc.id) { _, _ in
            cache.clear()
        }
        .onDisappear {
            cache.clear()
        }
    }
}

/// The image arm: a single zoomable image — no pager, no cache (an image is
/// one page). Serves the composite identically: only the `DocumentId`
/// supertype arrives here, so no barcode field can leak in.
private struct FullScreenImageView: View {
    let documentId: any DocumentId
    let source: ImageDecodeSource
    let decoder: any BoundedImageDecoder
    let telemetry: DocumentTelemetryGuard

    @State private var viewModel = DocumentImageViewModel()

    var body: some View {
        content
            .task(id: documentId.value) {
                viewModel.start(
                    documentId: documentId,
                    source: source,
                    decoder: decoder,
                    maxPixelSize: FullScreenDocumentView.fullScreenMaxPixelSize,
                    telemetry: telemetry
                )
            }
            .onDisappear {
                viewModel.stop()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            Color.clear
        case .failed:
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Image couldn't be displayed")
        case .rendered(let handle, _):
            ZoomableContent {
                handle.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityElement()
            .accessibilityLabel("Image document")
        }
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

    var body: some View {
        content
            .onAppear {
                viewModel.start(
                    document: document,
                    page: pageIndex,
                    source: pages,
                    context: ThumbnailRenderContext(telemetry: telemetry, cache: cache),
                    maxPixelSize: FullScreenDocumentView.fullScreenMaxPixelSize
                )
            }
            .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            Color.clear
        case .failed:
            // Nothing renders (Android mirror), but a render-once failure can
            // be permanent, so the page announces itself to VoiceOver.
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(
                    "Page \(pageIndex + 1) of \(document.pageCount) couldn't be displayed"
                )
        case .rendered(let image, _):
            ZoomableContent {
                image.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(pageIndex + 1) of \(document.pageCount)")
        }
    }
}
