import PassesImage
import PassesPDFCore
import PassesUICore
import SwiftUI

/// Presentation of a `Document` — the public entry point the consumer composes,
/// a dispatcher on the sealed `Document` arm set (mirror of Android's
/// `DocumentView`): `PDFDocument` routes to the swipeable stored-raster pager;
/// `ImageDocument` routes to a single, no-pager image over the §7 bounded
/// image decode; `BarcodedImageDocument` (wpass-8lu) routes to the SAME image
/// surface for its image half — the generated barcode and format switcher are
/// composed by the consumer with `PassesUI`, so this surface stays image-only
/// and the two UI towers remain independent.
///
/// Trust contract (all arms):
///
///  - The non-suppressible `DocumentTrustCaption` is rendered inside every
///    arm and is not gated by any parameter. No `DocumentView` overload
///    omits it. The surface-lock test pins the parameter shape; the trust
///    surface test pins the visible-text contract.
///  - The view displays only Walt-produced pixels and the caption. ADR 0005
///    D4: no PDF metadata, no image EXIF, no extracted text.
///  - No share, export, print, or open-with affordance. ADR 0005 D8.
///  - Inline surfaces are fixed 1x: no pinch-zoom, no pan. Zoom lives only on
///    the full-screen detail surface (`FullScreenDocumentView`).
///
/// The backend handles are kind-specific and optional: a consumer supplies
/// `pages` (the ios-dts.16 stored-raster source) for a `PDFDocument`, and the
/// `imageSource` / `imageDecoder` pair for an `ImageDocument` or
/// `BarcodedImageDocument` — `imageSource` is the ORIGINAL image bytes, whose
/// display-scale re-decode is allowed only through the bounded decoder (the
/// §7 lane; `image-decode-1`). Prefer `.fileURL` for display: a `.data` source
/// keeps the whole original resident on this struct for the surface lifetime,
/// where a file URL keeps Data Protection on the bytes until the lane reads
/// them. The dispatcher requires the pair matching the
/// arm; passing a document without its backend is a programming error and
/// fails fast, so a consumer showing one kind never fabricates the other
/// backend.
///
/// `faceTint` (wpass-80y.2 mirror) is presentation only — the kernel never
/// learns why a color was chosen and stores nothing. The tint reaches the
/// FRAME the page render / decoded image sits on and nothing else, in both
/// arms: the content is real and renders identically tinted or not, and
/// identically in light and dark. The rounded card shape arrives WITH the
/// tint (paint only, never a clip); `nil` and a fully transparent tint both
/// mean "no tint" via the shared `faceIsTinted`. Pass an opaque color.
public struct DocumentView: View {
    public let doc: any Document
    public let pages: (any DocumentPageSource)?
    public let imageSource: ImageDecodeSource?
    public let imageDecoder: (any BoundedImageDecoder)?
    public let telemetry: DocumentTelemetryGuard
    public let onOpenFullScreen: (() -> Void)?
    public let faceTint: ArgbColor?

    public init(
        doc: any Document,
        pages: (any DocumentPageSource)? = nil,
        imageSource: ImageDecodeSource? = nil,
        imageDecoder: (any BoundedImageDecoder)? = nil,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared,
        onOpenFullScreen: (() -> Void)? = nil,
        faceTint: ArgbColor? = nil
    ) {
        self.doc = doc
        self.pages = pages
        self.imageSource = imageSource
        self.imageDecoder = imageDecoder
        self.telemetry = telemetry
        self.onOpenFullScreen = onOpenFullScreen
        self.faceTint = faceTint
    }

    public var body: some View {
        switch doc {
        case let pdf as PDFDocument:
            PdfDocumentView(
                doc: pdf,
                pages: required(pages, "DocumentView(PDFDocument) requires a non-nil pages"),
                telemetry: telemetry,
                onOpenFullScreen: onOpenFullScreen,
                faceTint: faceTint
            )
        // wpass-8lu: a composite renders its IMAGE half through the same
        // bounded image surface as a plain image (same imageSource /
        // imageDecoder pair, no new DocumentView parameter). The barcode half
        // is consumer-composed with PassesUI.
        case is ImageDocument, is BarcodedImageDocument:
            ImageDocumentView(
                documentId: doc.documentId,
                source: required(
                    imageSource, "DocumentView(\(type(of: doc))) requires a non-nil imageSource"),
                decoder: required(
                    imageDecoder, "DocumentView(\(type(of: doc))) requires a non-nil imageDecoder"),
                telemetry: telemetry,
                onOpenFullScreen: onOpenFullScreen,
                faceTint: faceTint
            )
        default:
            // `DocumentSealedSetTests` fails when `documentArms` grows; this
            // switch must then be reconciled BY HAND — the pin is test-time,
            // not compile-time (Swift has no sealed protocols).
            fatalError("DocumentView: unknown Document arm \(type(of: doc))")
        }
    }

    private func required<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
        guard let value else { fatalError(message()) }
        return value
    }

    /// Pure face decision routed through the shared `faceIsTinted` gate so the
    /// body cannot skip it — `nil` means "keep the flush laneBackground frame".
    /// Internal so a test pins BOTH directions (the wpass-80y.5 lesson); shared
    /// by both arms so they cannot drift on the one thing `faceTint` touches.
    static func resolvedFace(_ faceTint: ArgbColor?) -> ArgbColor? {
        faceIsTinted(faceTint) ? faceTint : nil
    }

    /// Card radius from the 26.08.08 design's card anatomy spec. Duplicated as
    /// `cardRadius` in `PassesUI`'s `ScannableCardScreen` (the Android wpass-nbr
    /// shared-token hoist is still open there too).
    static let faceRadius: CGFloat = 20

    /// Longer-side cap for the inline surfaces' decoded pixels, shared by the
    /// pager's stored-raster inflate and the image arm's bounded decode. The
    /// inline card slot never shows more than ~400 pt of width, so 1200 px
    /// covers a 3x display crisply while keeping `defaultPageWindow` pages of
    /// cache under ~20 MB where the uncapped decode would hold ~80 MB.
    /// Internal so the decode-budget test pins against the source of truth.
    static let inlineMaxPixelSize: Int = 1200
}

/// The ONE face both arms paint their slot with, so they cannot drift on the
/// single thing `faceTint` touches (contract on `DocumentView`'s type doc).
/// Background only — never a clip or filter over the content.
@MainActor
@ViewBuilder
private func documentFace(faceTint: ArgbColor?, style: DocumentSemantics) -> some View {
    if let tint = DocumentView.resolvedFace(faceTint) {
        RoundedRectangle(cornerRadius: DocumentView.faceRadius)
            .fill(tint.swiftUIColor)
    } else {
        style.laneBackground.swiftUIColor
    }
}

/// Presentation of a `PDFDocument` — the non-suppressible trust caption above a
/// swipeable pager of stored Walt-produced rasters (ios-dts.16 render-once:
/// this module holds no PDF parser and cannot re-parse the original bytes).
/// Fills the bounds the consumer gives it and does NOT assume a full screen.
private struct PdfDocumentView: View {
    let doc: PDFDocument
    let pages: any DocumentPageSource
    let telemetry: DocumentTelemetryGuard
    let onOpenFullScreen: (() -> Void)?
    let faceTint: ArgbColor?

    @State private var currentPage: Int = 0
    @State private var cache: PDFThumbnailCache = PDFThumbnailCache()

    @Environment(\.documentSemantics) private var semantics

    var body: some View {
        let style = semantics ?? .placeholder
        VStack(spacing: 8) {
            DocumentTrustCaption()
            pager(style: style)
            if let onOpenFullScreen {
                FullScreenBanner(
                    label: style.fullScreenBannerLabel, style: style, action: onOpenFullScreen)
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
        .background(documentFace(faceTint: faceTint, style: style))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen?()
        }
    }
}

/// Presentation of an `ImageDocument` — the non-suppressible trust caption
/// above a single, fixed-fit image: the image-arm analogue of
/// `PdfDocumentView`, minus the pager (an image is a single page, so no
/// `TabView` and no cache). The original image is decoded once through the §7
/// bounded lane (the caller-supplied `BoundedImageDecoder` protocol, never a
/// concrete type) and the raster is letterboxed into the slot. A
/// `BarcodedImageDocument` renders its image half here identically — the
/// dispatcher passes only the `documentId` supertype, so this surface cannot
/// tell the arms apart, which is the point: no barcode field can leak in.
///
/// ADR 0005 D4: no image metadata, no EXIF, no extracted text — the
/// accessibility label is a fixed neutral string. Loading/Failed render
/// nothing inline; the lane tone is the placeholder, matching the PDF arm.
private struct ImageDocumentView: View {
    let documentId: any DocumentId
    let source: ImageDecodeSource
    let decoder: any BoundedImageDecoder
    let telemetry: DocumentTelemetryGuard
    let onOpenFullScreen: (() -> Void)?
    let faceTint: ArgbColor?

    @State private var viewModel = DocumentImageViewModel()

    @Environment(\.documentSemantics) private var semantics

    var body: some View {
        let style = semantics ?? .placeholder
        VStack(spacing: 8) {
            DocumentTrustCaption()
            imageSlot(style: style)
            if let onOpenFullScreen {
                FullScreenBanner(
                    label: style.fullScreenBannerLabel, style: style, action: onOpenFullScreen)
            }
        }
        // The restart key (Android's produceState keys, wpass-8lu): fires on
        // appear, on REappear, and whenever the document changes in place — a
        // consumer swapping `doc` at a stable tree position must never keep
        // the previous document's pixels on a trust surface.
        .task(id: documentId.value) {
            viewModel.start(
                documentId: documentId,
                source: source,
                decoder: decoder,
                maxPixelSize: DocumentView.inlineMaxPixelSize,
                telemetry: telemetry
            )
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    @ViewBuilder
    private func imageSlot(style: DocumentSemantics) -> some View {
        Group {
            switch viewModel.state {
            case .loading:
                Color.clear
            case .failed:
                // Nothing renders inline (Android parity); the slot at least
                // announces itself to VoiceOver, like the PDF arm's pages.
                // `.accessibilityElement()` makes the empty color an element —
                // a label on a non-element is silently skipped.
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("Image couldn't be displayed")
            case .rendered(let handle, _):
                handle.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // D4 forbids extracting text/metadata from the image; a
                    // fixed neutral label is the only safe VoiceOver fallback.
                    // The handle's Image is decorative, so the element is
                    // created here.
                    .accessibilityElement()
                    .accessibilityLabel("Image document")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(documentFace(faceTint: faceTint, style: style))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen?()
        }
    }
}

/// Docked discoverability hint below the content. When the consumer provides
/// no `onOpenFullScreen` the banner is absent; when wired the content itself
/// is also a tap target (handled at the slot level in both arms).
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
                    context: ThumbnailRenderContext(telemetry: telemetry, cache: cache),
                    maxPixelSize: DocumentView.inlineMaxPixelSize
                )
            }
            .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            // Mirror of Android: loading renders nothing in the inline
            // surface; the pager itself is the placeholder.
            Color.clear
        case .failed:
            // Visually inherited from Android (nothing renders), but since
            // render-once a failure can be permanent (missing raster), so the
            // page at least announces itself to VoiceOver.
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(
                    "Page \(pageIndex + 1) of \(document.pageCount) couldn't be displayed"
                )
        case .rendered(let image, _):
            image.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityElement()
                .accessibilityLabel("Page \(pageIndex + 1) of \(document.pageCount)")
        }
    }

}
