import Foundation

/// The shapes a PDF can enter the importer in.
///
/// Mirrors Android's `PdfImportSource` sealed interface (`ContentUri` /
/// `FileDescriptor`). On iOS there is no `ContentResolver`; the document-picker
/// hand-off surfaces as a file URL, so the platform-neutral analogues are a
/// file-system URL and an in-memory byte buffer.
///
/// Sealed by design: every byte that reaches the renderer has to be sourced
/// from one of these arms. There is intentionally no path-string arm and no
/// remote-URL arm: trust-claim-bearing import code never opens an arbitrary
/// filesystem path itself, and the importer never fetches bytes from the
/// network. The two arms together cover every legitimate user-initiated
/// import without admitting that surface.
///
/// Ownership: the caller owns the file URL and the `Data` buffer; the
/// importer reads but does not retain references beyond the suspend call.
public enum PDFImportSource: Sendable {
    /// A file URL the user picked from `UIDocumentPickerViewController` or the
    /// equivalent macOS open panel. Must be a `file://` URL; non-file schemes
    /// are rejected at materialization time as `.notAPdf`, mirroring the
    /// scheme allowlist in the Android `ContentUri` arm.
    case fileURL(URL)

    /// An already-materialized in-memory PDF buffer. Used when the consumer
    /// has the bytes in hand (an attachment, share-sheet input, in-process
    /// data) and does not want a file-system round-trip.
    case data(Data)
}
