import Foundation

/// The five PKPASS pass styles. Subtype labels (e.g. `boardingPass.transitType`) are surfaced
/// via the localized strings rather than enumerated here, per decision-wlt-0tn-q2.
public enum PassType: Sendable, CaseIterable {
    case boardingPass
    case eventTicket
    case coupon
    case storeCard
    case generic
}
