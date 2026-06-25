import Foundation

/// The single choke point that turns a raw `ScannableCardCreateInput` into a trusted
/// `ScannableCard`. Existence of a `ScannableCard` value asserts that this validator approved
/// it (the artifact's initializer is `internal` so no other path can mint one).
///
/// The `id` and `createdAt` parameters are caller-provided because PassesCore does not mint
/// IDs (see `ScannableCardId`'s doc — storage assigns them) and the clock is injected so
/// tests are deterministic. The validator only judges field content; it does not allocate
/// identity or time.
///
/// Fail-fast: returns the first violation found. Label trimmed first (a whitespace-only
/// label is empty for users), then payload (trim, empty, bidi/control, length, charset,
/// structural). Both trimmed values land on the resulting `ScannableCard`.
public enum ScannableCardInputValidator {
    /// Display-friendly cap. Long enough for any realistic card name, short enough to render.
    public static let maxLabelLength: Int = 64

    public static func validate(
        input: ScannableCardCreateInput,
        id: ScannableCardId,
        createdAt: PassInstant
    ) -> ScannableCardCreateResult {
        let trimmedLabel = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = validateLabel(trimmedLabel) {
            return .invalidLabel(reason: rejection)
        }

        let trimmedPayload = input.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = validatePayload(trimmedPayload, format: input.format) {
            return .invalidPayload(reason: rejection)
        }

        return .success(
            card: ScannableCard(
                id: id,
                payload: trimmedPayload,
                format: input.format,
                label: trimmedLabel,
                createdAt: createdAt
            )
        )
    }

    private static func validateLabel(_ label: String) -> LabelRejection? {
        if label.isEmpty { return .empty }
        // Bidi/control check before length so a 200-char string of bidi marks reports the
        // hazardous content, not just its size.
        for scalar in label.unicodeScalars {
            if isFormatChar(scalar) { return .containsBidiChar }
            if isControlChar(scalar) { return .containsControlChar }
        }
        if label.count > maxLabelLength {
            return .tooLong(actual: label.count, max: maxLabelLength)
        }
        return nil
    }

    private static func validatePayload(
        _ payload: String,
        format: ScannableFormat
    ) -> PayloadRejection? {
        if payload.isEmpty { return .empty }
        // Bidi/control check before length/charset so the error tells the user "your input
        // contains a hidden character," not "U+0000 is not in the EAN-13 charset."
        for scalar in payload.unicodeScalars {
            if isFormatChar(scalar) { return .containsBidiChar }
            if isControlChar(scalar) { return .containsControlChar }
        }
        // Fixed-length symbologies (EAN-13, UPC-A): exact-length check surfaces wrongLength
        // for both too-short AND too-long inputs, so the consumer never has to choose between
        // tooLong and wrongLength for the same logical mistake. Variable-length symbologies
        // use the soft cap and emit tooLong.
        if let required = ScannableFormatConstraints.requiredLength(format) {
            if payload.count != required {
                return .wrongLength(actual: payload.count, required: required, format: format)
            }
        } else {
            let max = ScannableFormatConstraints.maxPayloadLength(format)
            if payload.count > max {
                return .tooLong(actual: payload.count, max: max)
            }
        }
        for char in payload where !ScannableFormatConstraints.isAllowedChar(format: format, char: char) {
            return .wrongCharset(format: format, offendingChar: char)
        }
        return ScannableFormatConstraints.validateStructural(format: format, payload: payload)
    }

    /// Unicode general category Cf (Format). Mirrors Kotlin's `CharCategory.FORMAT`. Catches
    /// bidi controls (U+202A..U+202E etc.) without enumerating individual codepoints.
    private static func isFormatChar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format
    }

    /// Unicode general category Cc (Control). Mirrors Kotlin's `Char.isISOControl()`, which is
    /// defined as the Cc category (U+0000..U+001F and U+007F..U+009F).
    private static func isControlChar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}
