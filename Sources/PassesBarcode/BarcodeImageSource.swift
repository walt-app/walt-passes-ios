import Foundation

/// The two shapes a candidate image can enter the still-image decoder in (mirror of Android
/// `BarcodeImageSource`). There is deliberately no `String`/path arm the decoder resolves itself:
/// opening arbitrary filesystem paths would let a future contributor route bytes from locations the
/// consumer never intended. The caller resolves the source; the decoder only reads what it is handed
/// (and never deletes or moves it).
///
/// The `.data` arm is a **deviation from Android** (ADR `barcode-decode-1`): Android forbids a
/// `ByteArray` source because a byte array in its `isolatedProcess` model means the hostile image
/// already reached the main-process heap. iOS drops that containment premise (it has no isolated
/// child; Vision decodes out-of-process instead), so `.data` is acceptable — and the app's
/// `PHPicker` path naturally yields either in-memory `Data` or a temporary file `URL`.
public enum BarcodeImageSource: Sendable {
    /// The image already resident in memory (e.g. a `PHPickerResult` in-memory representation).
    case data(Data)

    /// A file `URL` the consumer has already resolved to a readable on-disk image.
    case fileURL(URL)
}
