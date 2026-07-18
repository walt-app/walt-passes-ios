import Foundation

/// The two shapes a candidate image can enter the still-image decoder in (mirror of Android
/// `BarcodeImageSource`). A closed pair: every byte the decoder reads is sourced either from a
/// file `URL` the consumer already resolved (the `PHPicker` / document-picker copy-out the app
/// wires in A9) or from in-memory `Data` the consumer already holds.
///
/// There is intentionally no `String`/path arm that the decoder would resolve itself: a decoder
/// that opened arbitrary filesystem paths would let a future contributor route bytes from
/// locations the consumer never intended. The caller resolves the source; the decoder only reads
/// what it is handed.
///
/// ## Deviation from Android (accepted, ADR `barcode-decode-1`)
/// Android forbids a `ByteArray` arm because it decodes inside an `isolatedProcess` and a byte
/// array would mean the hostile image had already been pulled into the main-process heap,
/// defeating the isolation. iOS **cannot** spawn an isolated-UID child, so that containment claim
/// is dropped for iOS: the compensating controls are the roster clamp, the bounded `CGImageSource`
/// decode, and running the symbol decode itself in Apple **Vision** (system services,
/// out-of-process). A `.data` arm is therefore acceptable here — the app's `PHPicker` image path
/// naturally yields either in-memory `Data` or a temporary file `URL`.
///
/// Ownership: the caller retains ownership of any file the `URL` points at; the decoder reads from
/// it but does not delete or move it.
public enum BarcodeImageSource: Sendable {
    /// The image already resident in memory (e.g. a `PHPickerResult` in-memory representation).
    case data(Data)

    /// A file `URL` the consumer has already resolved to a readable on-disk image.
    case fileURL(URL)
}
