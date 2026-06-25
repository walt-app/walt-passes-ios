import Foundation
import PassesPDFCore

/// The single import entry point for `PassesPDF`. Mirrors Android's
/// `PdfImporter` interface (ADR 0005 G.1's orchestration seam). Owns the
/// trust-claim-bearing orchestration that the consumer (walt-ios) would
/// otherwise have to assemble itself:
///
///  1. Bounded materialization of the source bytes with a fail-fast size cap.
///  2. Magic-byte header sniff before the renderer is invoked.
///  3. Renderer session connect -> probe -> page-zero render.
///  4. Storage hand-off via a caller-supplied `persist` callback.
///  5. Telemetry start / success / failure with enums-and-durations only.
///
/// Composing those by hand in walt-ios would be the parallel-implementation
/// pattern the repository forbids: trust claims must live in this repository,
/// not be reassembled by the consumer. ``PDFImporter`` is the seam that keeps
/// that invariant honest - every import goes through this orchestration, and
/// every step is independently testable via the package-internal seams.
///
/// Storage is wired through a callback rather than a `PassRepository`
/// dependency so `PassesPDF` and `PassesStorage` remain independent peers per
/// the project's module rules. The consumer supplies a closure that calls
/// the storage layer; the importer itself stays storage-agnostic.
public protocol PDFImporter: Sendable {
    /// Run the import sequence end-to-end. Returns
    /// ``PassesPDFCore/PDFImportResult/imported(doc:)`` on success, or
    /// ``PassesPDFCore/PDFImportResult/rejected(kind:)`` folded onto the
    /// ``PassesPDFCore/DocumentRejectedKind`` enum at the first failing step.
    /// The renderer session is closed before this method returns regardless
    /// of outcome.
    ///
    /// `persist` is invoked exactly once on the success path, after the
    /// page-zero render succeeds and before the
    /// ``PassesPDFCore/PDFImportResult/imported(doc:)`` arm is constructed.
    /// It is never invoked on a rejection. If `persist` throws (other than
    /// `CancellationError`, which is rethrown to preserve structured
    /// concurrency), the import returns
    /// ``PassesPDFCore/DocumentRejectedKind/storageHandoffFailed`` - distinct
    /// from the renderer's own
    /// ``PassesPDFCore/DocumentRejectedKind/rendererFailed`` so telemetry can
    /// separate "PDFKit choked on this file" from "the consumer's storage
    /// layer blew up." Telemetry fires `onImportFailed`.
    ///
    /// `displayLabel` is supplied by the consumer; the importer does not
    /// derive it from the source, because the source's metadata is part of
    /// the no-extraction-from-content discipline (ADR 0005 D4). The label is
    /// forwarded verbatim to `persist`.
    func `import`(
        source: PDFImportSource,
        displayLabel: String,
        persist:
            @Sendable (_ label: String, _ pdfBytes: Data, _ pageCount: Int, _ thumbnailBytes: Data) async throws -> Void
    ) async throws -> PDFImportResult
}

/// Convenience factory. Production consumers obtain a ``PDFImporter`` via
/// ``makePDFImporter(config:)``; the underlying ``DefaultPDFImporter`` is
/// package-private so test seams are not part of the public surface.
public func makePDFImporter(
    config: PDFImportConfig = PDFImportConfig()
) -> PDFImporter {
    DefaultPDFImporter(config: config)
}
