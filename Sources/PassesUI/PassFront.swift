import Foundation
import PassesCore
import PassesUICore

/// Front-facing pass surface. Mirror of `is.walt.passes.ui.PassFront`.
/// Scaffold for the walt-passes-ios standup; SwiftUI implementation lands with
/// the PassesUI port bead.
public protocol PassFrontRendering: Sendable {
    func render(pass: Pass) async -> PassFrontView
}

/// Placeholder for a rendered front face. Real type is a SwiftUI view in the
/// production port; this struct keeps the surface compileable.
public struct PassFrontView: Sendable, Equatable {
    public let passId: String
    public let title: String

    public init(passId: String, title: String) {
        self.passId = passId
        self.title = title
    }
}
