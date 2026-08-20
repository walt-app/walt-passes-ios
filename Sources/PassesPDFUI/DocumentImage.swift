import Foundation
import PassesImage
import PassesPDFCore
import SwiftUI

/// Outcome of a single-image decode — the image-arm sibling of
/// ``PDFThumbnailState`` (mirror of Android's `DocumentImageState`). Drives the
/// consumer's placeholder / image / error chrome from a single closed set. The
/// shape is narrow by design: no field through which a consumer could surface
/// image metadata or EXIF — the image-document trust posture mirrors the PDF
/// one (ADR 0005 D4). `DocumentImageSurfaceTests` locks the arms.
public enum DocumentImageState: Sendable {
    case loading
    case rendered(image: DocumentImageHandle, sourceAspect: Float)
    case failed(kind: ImageDecodeRejectedKind)
}

/// Wrapper around the decoded image (sibling of ``PageImageHandle``). Carries a
/// `SwiftUI.Image` for drawing plus the source aspect ratio; the pixels are held
/// by reference (a `CGImage`), so passing the handle around does not copy them,
/// and they release with the handle (the `recycle`-on-dispose analogue is ARC).
public struct DocumentImageHandle: Sendable {
    public let image: Image
    public let sourceAspect: Float

    init(decoded: DecodedDocumentImage) {
        self.image = decoded.image
        self.sourceAspect = decoded.sourceAspect
    }
}

/// SwiftUI-friendly facade over the bounded in-process image decode for a
/// single image document — the iOS analogue of Android's `rememberDocumentImage`
/// composable and the image-arm counterpart of ``PDFThumbnailViewModel``. It
/// consumes a caller-supplied ``PassesImage/BoundedImageDecoder`` (it never
/// constructs its own, preserving the one-decoder-per-composition-root
/// discipline), decodes the ORIGINAL image bytes once through the §7 bounded
/// lane, and exposes only ``DocumentImageState``.
///
/// The same facade renders the image of an `ImageDocument` and the image half
/// of a `BarcodedImageDocument` (wpass-8lu) — `documentId` is the `DocumentId`
/// supertype, used only to name the load; the barcode half is rendered by the
/// consumer with `PassesUI`, never here.
///
/// Lifecycle the facade owns so consumers do not reimplement it: a
/// `start` → `start` rebind cancels the prior load; `stop()` cancels the
/// in-flight load on disappearance; a decode superseded mid-flight never
/// overwrites the newer state (the task checks its own cancellation before
/// publishing). There is no cache — an image is a single page.
@MainActor
@Observable
public final class DocumentImageViewModel {
    public private(set) var state: DocumentImageState = .loading

    private var loadTask: Task<Void, Never>?

    public init() {}

    /// Kick off the decode. `maxPixelSize` caps the request's longer side
    /// (both bounds — the decoder aspect-fits and never upscales).
    public func start(
        documentId: any DocumentId,
        source: ImageDecodeSource,
        decoder: any BoundedImageDecoder,
        maxPixelSize: Int,
        telemetry: DocumentTelemetryGuard = DocumentTelemetryGuardNoOp.shared
    ) {
        loadTask?.cancel()
        state = .loading
        let bound = max(1, maxPixelSize)
        loadTask = Task { [weak self] in
            let result = await decoder.decode(
                source: source, maxWidthPx: bound, maxHeightPx: bound)
            guard !Task.isCancelled else { return }
            self?.publish(result: result, telemetry: telemetry)
        }
    }

    /// Stop any in-flight decode. Called by hosting views on disappearance so
    /// the task does not survive the view; the decoded pixels release with the
    /// state's handle (ARC).
    public func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func publish(result: ImageDecodeResult, telemetry: DocumentTelemetryGuard) {
        switch foldDecodedImage(result, telemetry: telemetry) {
        case .rendered(let decoded):
            state = .rendered(
                image: DocumentImageHandle(decoded: decoded),
                sourceAspect: decoded.sourceAspect)
        case .failed(let kind):
            state = .failed(kind: kind)
        }
    }
}
