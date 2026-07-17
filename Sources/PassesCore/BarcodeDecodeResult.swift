import Foundation

/// The outcome of decoding a barcode/QR from a user-supplied static image or camera frame
/// (mirror of Android `BarcodeDecodeResult`). A pure model type living in `PassesCore` next to
/// `ScannableFormat`, reachable by both the decode facade (A6 seam → Vision impl) and any
/// consumer branching on the result, without either depending on the other. No engine, no
/// Vision, no dependency — see `docs/adr/barcode-decode-1.md`.
///
/// Enum for compile-time exhaustiveness, mirroring `ParseResult`. Two trust-claim invariants
/// are encoded in the shape itself:
///
///  1. The decoder returns the payload FAITHFULLY and never auto-acts on it. Classification
///     and validation stay downstream in the consumer's call to `QrPayloadKind` and
///     `ScannableCardInputValidator`; nothing here interprets the bytes.
///  2. No arm carries the source image bytes. The out-of-process decode (Vision runs in
///     system services) returns only `{payload, format}` — the hostile image never crosses
///     back into the caller's address space.
public enum BarcodeDecodeResult: Sendable, Equatable {
    /// A single barcode was located and decoded. `payload` is the raw decoded string exactly
    /// as the symbol carried it; `format` is the symbology, constrained to the
    /// `ScannableFormat` roster Walt renders. A symbol decoded in a format outside that roster
    /// is reported as `decodeFailed(reason: .unsupportedBarcodeFormat)`, not forced into an
    /// ill-fitting arm.
    case decodedBarcode(payload: String, format: ScannableFormat)

    /// The image decoded cleanly but carried no barcode the decoder could locate.
    case noBarcodeFound

    /// Decoding could not complete; `reason` buckets the failure for telemetry.
    case decodeFailed(reason: DecodeFailureReason)
}

/// Why a decode attempt failed, bucketed to the threat-model steps on barcode-decode-1 so
/// telemetry can tell "we never read the file" from "the codec rejected it" from "the decoder
/// went away." Enum (not free text) keeps the surface enumerable and the telemetry cardinality
/// bounded.
public enum DecodeFailureReason: Sendable, CaseIterable {
    /// The image source could not be opened or read.
    case sourceUnreadable

    /// The platform image codec could not decode the container into pixels.
    case imageDecodeFailed

    /// The image exceeded the bounded-decode dimension/megapixel/size caps (decompression-bomb guard).
    case imageTooLarge

    /// A symbol was found but its symbology is outside the `ScannableFormat` roster.
    case unsupportedBarcodeFormat

    /// The decode engine could not be reached or timed out before returning a result.
    case decoderUnavailable
}
