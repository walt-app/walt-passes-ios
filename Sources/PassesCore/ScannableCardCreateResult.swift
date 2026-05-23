import Foundation

/// Outcome of attempting to construct a `ScannableCard` from a `ScannableCardCreateInput`.
/// The arms partition along trust / recoverability lines so the consumer UI can render
/// distinct states without inspecting exception messages. No-throw contract: callers observe
/// outcomes via exhaustive `switch`, never via try/catch.
public enum ScannableCardCreateResult: Sendable, Equatable {
    case success(card: ScannableCard)
    case invalidPayload(reason: PayloadRejection)
    case invalidLabel(reason: LabelRejection)
    /// Build-time capability gap — the encoder for `format` is not wired in this kernel build.
    case unsupportedFormat(format: ScannableFormat)
    /// The encoder rejected an otherwise-valid payload at encode time (e.g. a Code39 input
    /// that passes charset checks but exceeds the symbology's encodable density). Distinct
    /// from validation failures so telemetry can distinguish "user typed something bad"
    /// from "the encoder said no."
    case encoderFailure(reason: EncoderFailureReason)
}

/// Why a user-typed payload was rejected before encoding. Distinct arms so the consumer UI
/// can surface a specific error string without inspecting raw input.
public enum PayloadRejection: Sendable, Equatable {
    /// Payload exceeds the per-format length cap (see `ScannableFormatConstraints`).
    case tooLong(actual: Int, max: Int)

    /// A character is not in the symbology's allowed charset (e.g. a letter in EAN-13).
    case wrongCharset(format: ScannableFormat, offendingChar: Character)

    /// Length mismatch for fixed-length symbologies (EAN-13 must be 13, UPC-A must be 12).
    case wrongLength(actual: Int, required: Int, format: ScannableFormat)

    /// Mod-10 check digit did not match for a fixed-length symbology (EAN-13, UPC-A).
    case invalidCheckDigit(format: ScannableFormat)

    /// Payload contained a Unicode Cc (Control) codepoint — rejected for all formats.
    case containsControlChar

    /// Payload contained a Unicode Cf (Format) codepoint — bidi controls etc., all formats.
    case containsBidiChar

    /// Payload was empty (after whitespace trimming).
    case empty
}

/// Why a user-typed label was rejected. Mirrors the bidi/control hygiene of `PayloadRejection`
/// because the label is rendered alongside untrusted user content.
public enum LabelRejection: Sendable, Equatable {
    /// Label exceeded the display-friendly cap (see `ScannableCardInputValidator`).
    case tooLong(actual: Int, max: Int)
    /// Label contained a Unicode Cf (Format) codepoint — bidi controls etc.
    case containsBidiChar
    /// Label contained a Unicode Cc (Control) codepoint.
    case containsControlChar
    /// Label was empty.
    case empty
}

/// Why the encoder rejected a structurally valid payload — i.e. one that already cleared
/// `ScannableCardInputValidator`. These arms exist because per-symbology validation cannot
/// fully predict the underlying encoder's encodability ceiling: a payload of the correct
/// length and charset can still fail to fit a chosen symbology's density rules (most often
/// Code39 with a pathological pattern, or QR pushed past its largest version). The arms
/// partition by recoverability so the consumer UI can suggest a different format vs.
/// surfacing an opaque "try again" message.
public enum EncoderFailureReason: Sendable, Equatable {
    /// The underlying writer rejected the payload at encode time. `format` identifies
    /// which writer failed (the consumer may suggest switching to a denser symbology). The
    /// raw encoder exception message is preserved on `detail` for the consumer's diagnostic
    /// surface; it is not user-facing copy and may be empty when the encoder did not
    /// provide one.
    ///
    /// **Do not propagate `detail` to telemetry verbatim.** It is the only third-party
    /// string that crosses the kernel boundary on this surface, and the underlying encoder
    /// has historically embedded input-derived substrings in its messages. Consumers that
    /// ship the field outside the device should hash or bucket it first.
    case writerRejected(format: ScannableFormat, detail: String)

    /// The payload is too dense to encode at the symbology's maximum version (only QR can
    /// surface this — the 1D writers reject density mismatches under `writerRejected`). Distinct
    /// arm so the consumer UI can specifically suggest shortening the payload rather than
    /// switching format.
    case payloadTooDense
}
