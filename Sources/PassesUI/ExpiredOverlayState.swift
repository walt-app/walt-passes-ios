import Foundation
import PassesCore

/// The non-suppressible "this pass is expired" overlay state. Computed from a
/// `Pass` at render time. UI code cannot construct `.none` for a pass that meets
/// the expired criteria; a host that wants to hide the badge for one pass has
/// to deliberately bypass the API.
///
/// Mirror of Android's `is.walt.passes.ui.ExpiredOverlayState`.
public enum ExpiredOverlayState: Sendable, Equatable {
    case none
    case expired(at: PassInstant)
    case voided

    /// Compute the overlay state at `nowEpochMillis`. The host supplies the
    /// clock so this function stays deterministic and platform-pure.
    public static func from(pass: Pass, nowEpochMillis: Int64) -> ExpiredOverlayState {
        if pass.voided { return .voided }
        guard let expiration = pass.expirationDate else { return .none }
        if expiration.epochMillis <= nowEpochMillis {
            return .expired(at: expiration)
        }
        return .none
    }
}
