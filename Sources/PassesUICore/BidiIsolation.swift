import Foundation

/// Unicode bidi-isolation primitives shared by every surface module that renders
/// user-controlled strings. Mirror of `is.walt.passes.ui.core.BidiIsolation`
/// (Android's top-level `isolated(s)` function plus the `FSI` / `PDI` constants).
public enum BidiIsolation {
    /// First Strong Isolate (U+2068). Opens an isolate that takes the directional
    /// class of the first strong-class character within.
    public static let fsi: Character = "\u{2068}"

    /// Pop Directional Isolate (U+2069). Closes the most recently opened isolate.
    public static let pdi: Character = "\u{2069}"

    /// Wrap `s` in Unicode First-Strong Isolate / Pop Directional Isolate
    /// (U+2068, U+2069). Inside the isolate the bidi algorithm treats the contents
    /// as a single neutral directional unit: characters within cannot reorder text
    /// outside, and surrounding directional context cannot reorder characters
    /// within. This is the recommended fence for displaying user-controlled
    /// strings in bidi-sensitive surfaces (UAX #9 §3.4 isolate formatting
    /// characters).
    ///
    /// Used in `PassesUI` (security sheets — verbatim URL / phone / email / org
    /// name) and in `PassesPDFUI` (document tile — user-controlled `displayLabel`
    /// / filename). Both surfaces combine this with consumer-side `Cf`/`Cc`
    /// rejection so the displayed string is rendered as-typed; an attacker can no
    /// longer craft a value that looks visually like a trusted string while
    /// parsing as a hostile one.
    ///
    /// Lives in `PassesUICore` so it does not have to be duplicated between
    /// `PassesUI` and `PassesPDFUI`; a duplicated bidi fence is exactly the kind
    /// of trust-claim-bearing logic the kernel commits NOT to parallel-implement.
    public static func isolated(_ s: String) -> String {
        "\(fsi)\(s)\(pdi)"
    }
}

/// Free-function alias matching Android's top-level `isolated(s)` call site.
/// Call sites in surface modules can `import PassesUICore` and use `isolated(x)`
/// verbatim, mirroring the Android source.
public func isolated(_ s: String) -> String {
    BidiIsolation.isolated(s)
}
