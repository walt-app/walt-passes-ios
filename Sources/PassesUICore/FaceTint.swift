/// Whether `faceTint` is a tint a card face should actually take — the gate for
/// the consumer-supplied face tints on `PassesUI`'s scannable face and
/// `PassesPDFUI`'s document frame.
///
/// `nil` is the iOS analogue of Compose's `Color.Unspecified`; a non-nil but
/// fully transparent tint must also read as "no tint" — painting it would leave
/// ink derived from luminance 0 over host paint the kernel cannot see (the
/// wpass-80y.5 bug). Shared by both surfaces so they cannot drift on that case.
/// Not trust-claim-bearing — neither surface can lose its trust caption either
/// way, so this decides legibility, not provenance.
///
/// Mirror of Android `is.walt.passes.ui.core.faceIsTinted`.
public func faceIsTinted(_ faceTint: ArgbColor?) -> Bool {
    guard let faceTint else { return false }
    // The alpha > 0 boundary is Android's (`alpha > 0f`): partial alpha is
    // accepted and documented consumer-side as "pass an opaque color".
    return faceTint.alpha > 0
}
