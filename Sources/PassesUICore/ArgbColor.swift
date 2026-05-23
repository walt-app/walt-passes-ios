import Foundation

/// A 32-bit ARGB color, packed `0xAARRGGBB`. Mirrors `passes-core`'s `ColorValue.rgb`
/// shape but with an alpha channel, since theme tokens may legitimately want to
/// express transparency that pass.json's RGB triplet cannot.
///
/// Lives in `PassesUICore` so both `PassesUI` (PKPASS theme tokens) and
/// `PassesPDFUI` (document theme tokens) can share the same ARGB shape without
/// either module depending on the other. The doc comments on the surface modules'
/// theme value types describe how each slot is consumed.
///
/// Mirror of `is.walt.passes.ui.core.ArgbColor`. Android wraps a signed `Int`;
/// iOS uses `UInt32` because Swift lacks Kotlin's unsigned-literal coercion and
/// a packed bit pattern reads more naturally as unsigned. The bit layout is
/// identical on the wire.
public struct ArgbColor: Sendable, Equatable, Hashable {
    public let argb: UInt32

    public init(argb: UInt32) {
        self.argb = argb
    }

    /// Alpha channel (`0xAA______`).
    public var alpha: UInt8 { UInt8((argb >> 24) & 0xFF) }
    /// Red channel (`0x__RR____`).
    public var red: UInt8 { UInt8((argb >> 16) & 0xFF) }
    /// Green channel (`0x____GG__`).
    public var green: UInt8 { UInt8((argb >> 8) & 0xFF) }
    /// Blue channel (`0x______BB`).
    public var blue: UInt8 { UInt8(argb & 0xFF) }
}
