import Foundation

/// 32-bit ARGB color. Mirror of `is.walt.passes.ui.core.ArgbColor`.
/// Scaffold for the walt-passes-ios standup; full conversion helpers + the
/// BidiIsolation surface land with the PassesUICore port bead.
public struct ArgbColor: Sendable, Equatable, Hashable {
    public let argb: UInt32

    public init(argb: UInt32) {
        self.argb = argb
    }

    public var alpha: UInt8 { UInt8((argb >> 24) & 0xFF) }
    public var red: UInt8 { UInt8((argb >> 16) & 0xFF) }
    public var green: UInt8 { UInt8((argb >> 8) & 0xFF) }
    public var blue: UInt8 { UInt8(argb & 0xFF) }
}
