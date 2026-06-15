import PassesCore
import SwiftUI

/// The canonical renderer of a pkpass's visible identity. Given the parsed `pass` and an
/// optional `userLabel` override, it renders either the signed `organizationName` alone (no
/// override, or an override equal to the signed name) or the override as the primary line
/// with the signed name as an eyebrow beneath it — the trust-caption rule: the signed
/// identity stays visible on the same surface whenever an override is active.
///
/// Every surface presenting a pass's primary identity SHOULD route through this view when an
/// override may be set. A row shape incompatible with the stacked layout MAY instead call
/// `resolvePassDisplayIdentity` directly for the same FSI/PDI-fenced `(primary, eyebrow)`
/// pair; inlining the trim/compare/fence on the consumer side is a trust-claim violation.
///
/// Type mapping (deviation ADR): Android's `labelLarge`/`labelSmall` map to `.callout`
/// (matching the eyebrow PassFront has always rendered) and `.caption`. The eyebrow uses a
/// single line; iOS ellipsizes where Android clips, but the issuer identity stays visible.
public struct PassIdentityBlock: View {
    private let pass: Pass
    private let userLabel: String?
    private let locale: PassLocale
    private let primaryColor: Color
    private let eyebrowColor: Color?

    public init(
        pass: Pass,
        userLabel: String?,
        locale: PassLocale = PassLocale("en"),
        primaryColor: Color = .primary,
        eyebrowColor: Color? = nil
    ) {
        self.pass = pass
        self.userLabel = userLabel
        self.locale = locale
        self.primaryColor = primaryColor
        self.eyebrowColor = eyebrowColor
    }

    public var body: some View {
        let identity = resolvePassDisplayIdentity(pass: pass, userLabel: userLabel, locale: locale)
        if let eyebrow = identity.eyebrow {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.primary)
                    .font(.callout)
                    .foregroundColor(primaryColor)
                    .lineLimit(2)
                Text(eyebrow)
                    .font(.caption)
                    .foregroundColor(eyebrowColor ?? primaryColor.opacity(0.7))
                    .lineLimit(1)
            }
        } else {
            Text(identity.primary)
                .font(.callout)
                .foregroundColor(primaryColor)
                .lineLimit(1)
        }
    }
}
