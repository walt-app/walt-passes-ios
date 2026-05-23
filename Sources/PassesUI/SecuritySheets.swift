import SwiftUI
import PassesCore
import PassesUICore

/// Security confirmation sheet for an outbound URL detected on a pass back
/// field. Displays the issuer, source field label, and verbatim URL the host
/// is about to open. `onConfirm` fires only on the user's explicit confirm tap.
///
/// `emphasisStyle` chooses between `.container` (default, behavior-identical to
/// pre-wpass-48v) and `.domainHero` (the trust-claim-safer alternative).
///
/// Mirror of Android's `B3UrlConfirmSheet`.
public struct B3UrlConfirmSheet: View {
    let intent: B3UrlIntent
    let passType: PassType
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let emphasisStyle: B3EmphasisStyle

    public init(
        intent: B3UrlIntent,
        passType: PassType,
        telemetry: any UiTelemetryGuard,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        emphasisStyle: B3EmphasisStyle = .container
    ) {
        self.intent = intent
        self.passType = passType
        self.telemetry = telemetry
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.emphasisStyle = emphasisStyle
    }

    public var body: some View {
        SecuritySheet(
            kind: .url,
            passType: passType,
            title: "Open this link?",
            target: intent.url,
            hero: intent.registrableDomain,
            source: intent.sourceField,
            confirmCopy: emphasisStyle == .domainHero ? "Open in browser" : "Open link",
            emphasisStyle: emphasisStyle,
            telemetry: telemetry,
            onConfirm: onConfirm,
            onDismiss: onDismiss
        )
    }
}

/// Security confirmation sheet for an outbound phone number. Mirror of Android's
/// `PhoneConfirmSheet`.
public struct PhoneConfirmSheet: View {
    let intent: PhoneIntent
    let passType: PassType
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let emphasisStyle: B3EmphasisStyle

    public init(
        intent: PhoneIntent,
        passType: PassType,
        telemetry: any UiTelemetryGuard,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        emphasisStyle: B3EmphasisStyle = .container
    ) {
        self.intent = intent
        self.passType = passType
        self.telemetry = telemetry
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.emphasisStyle = emphasisStyle
    }

    public var body: some View {
        SecuritySheet(
            kind: .phone,
            passType: passType,
            title: "Call this number?",
            target: intent.phoneNumber,
            hero: phoneHero(intent.phoneNumber),
            source: intent.sourceField,
            confirmCopy: "Call",
            emphasisStyle: emphasisStyle,
            telemetry: telemetry,
            onConfirm: onConfirm,
            onDismiss: onDismiss
        )
    }
}

/// Security confirmation sheet for an outbound email address. Displays the
/// verbatim address; the host's compose action receives ONLY the address (no
/// subject, no body). Mirror of Android's `EmailConfirmSheet`.
public struct EmailConfirmSheet: View {
    let intent: EmailIntent
    let passType: PassType
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let emphasisStyle: B3EmphasisStyle

    public init(
        intent: EmailIntent,
        passType: PassType,
        telemetry: any UiTelemetryGuard,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        emphasisStyle: B3EmphasisStyle = .container
    ) {
        self.intent = intent
        self.passType = passType
        self.telemetry = telemetry
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.emphasisStyle = emphasisStyle
    }

    public var body: some View {
        SecuritySheet(
            kind: .email,
            passType: passType,
            title: "Send an email?",
            target: intent.emailAddress,
            hero: emailHostHero(intent.emailAddress),
            source: intent.sourceField,
            confirmCopy: "Compose",
            emphasisStyle: emphasisStyle,
            telemetry: telemetry,
            onConfirm: onConfirm,
            onDismiss: onDismiss
        )
    }
}

internal func phoneHero(_ phone: String) -> String {
    let trimmed = phone.trimmingCharacters(in: .whitespaces)
    let collapsed = trimmed.replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
    )
    return collapsed
}

internal func emailHostHero(_ email: String) -> String {
    guard let at = email.firstIndex(of: "@") else { return email }
    let after = email.index(after: at)
    if after >= email.endIndex { return email }
    return String(email[after...])
}

private struct SecuritySheet: View {
    let kind: SecurityIntentKind
    let passType: PassType
    let title: String
    let target: String
    let hero: String?
    let source: SourceField
    let confirmCopy: String
    let emphasisStyle: B3EmphasisStyle
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(\.passesSemantics) private var semantics

    var body: some View {
        let emphasis = semantics?.securitySheet
        VStack(alignment: .leading, spacing: 12) {
            switch emphasisStyle {
            case .container:
                ContainerLayout(
                    emphasis: emphasis,
                    title: title,
                    target: target,
                    source: source,
                    confirmCopy: confirmCopy,
                    kind: kind,
                    passType: passType,
                    telemetry: telemetry,
                    onConfirm: onConfirm,
                    onDismiss: onDismiss
                )
            case .domainHero:
                DomainHeroLayout(
                    emphasis: emphasis,
                    target: target,
                    hero: hero ?? target,
                    source: source,
                    confirmCopy: confirmCopy,
                    kind: kind,
                    passType: passType,
                    telemetry: telemetry,
                    onConfirm: onConfirm,
                    onDismiss: onDismiss
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((emphasis?.sheetBackground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
        .onAppear {
            telemetry.onSecuritySheetShown(intentKind: kind, type: passType)
        }
    }
}

private struct ContainerLayout: View {
    let emphasis: SecuritySheetStyle?
    let title: String
    let target: String
    let source: SourceField
    let confirmCopy: String
    let kind: SecurityIntentKind
    let passType: PassType
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Text(title)
            .font(.title2)
            .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
        Text(
            isolated(source.organizationName) +
                (source.fieldLabel.map { " — \(isolated($0))" } ?? "")
        )
        .font(.caption)
        .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
        VStack(alignment: .leading, spacing: 4) {
            Text(isolated(target))
                .font(.body)
                .foregroundColor((emphasis?.emphasisForeground ?? ArgbColor(argb: 0xFF000000)).swiftUIColor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((emphasis?.emphasisBackground ?? ArgbColor(argb: 0xFFEFEFEF)).swiftUIColor)
        )
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") {
                telemetry.onSecuritySheetDismissed(intentKind: kind, type: passType)
                onDismiss()
            }
            .foregroundColor((emphasis?.cancelForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            Button(confirmCopy) {
                telemetry.onSecuritySheetConfirmed(intentKind: kind, type: passType)
                onConfirm()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule().fill((emphasis?.confirmContainer ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            )
            .foregroundColor((emphasis?.confirmForeground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
        }
    }
}

private struct DomainHeroLayout: View {
    let emphasis: SecuritySheetStyle?
    let target: String
    let hero: String
    let source: SourceField
    let confirmCopy: String
    let kind: SecurityIntentKind
    let passType: PassType
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let body = (emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor
        let eyebrow = (emphasis?.eyebrowForeground ?? ArgbColor(argb: 0xFF73777F)).swiftUIColor
        let muted = (emphasis?.mutedForeground ?? ArgbColor(argb: 0xFFC4C7C5)).swiftUIColor
        let eyebrowCopy: String = {
            switch kind {
            case .url: return "LEAVING WALT"
            case .phone: return "CALLING"
            case .email: return "EMAILING"
            }
        }()
        Text(eyebrowCopy)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(eyebrow)
        Text(isolated(hero))
            .font(.title2.weight(.semibold))
            .foregroundColor(body)
        Text(isolated(target))
            .font(.caption.monospaced())
            .foregroundColor(muted)
        provenanceText(source: source, bodyColor: body, dimColor: muted)
            .font(.caption)
            .foregroundColor(muted)
        Rectangle()
            .fill(muted)
            .frame(height: 1)
        HStack(spacing: 12) {
            Button("Cancel") {
                telemetry.onSecuritySheetDismissed(intentKind: kind, type: passType)
                onDismiss()
            }
            .frame(maxWidth: .infinity)
            .foregroundColor((emphasis?.cancelForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            Button(confirmCopy) {
                telemetry.onSecuritySheetConfirmed(intentKind: kind, type: passType)
                onConfirm()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule().fill((emphasis?.confirmContainer ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            )
            .foregroundColor((emphasis?.confirmForeground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
        }
    }

    private func provenanceText(
        source: SourceField,
        bodyColor: Color,
        dimColor: Color
    ) -> Text {
        let org = isolated(source.organizationName)
        if let label = source.fieldLabel.map({ isolated($0) }) {
            return Text("From the ")
                .foregroundColor(dimColor)
                + Text(label).foregroundColor(bodyColor).bold()
                + Text(" field on your ").foregroundColor(dimColor)
                + Text(org).foregroundColor(bodyColor).bold()
                + Text(" pass.").foregroundColor(dimColor)
        }
        return Text("From your ")
            .foregroundColor(dimColor)
            + Text(org).foregroundColor(bodyColor).bold()
            + Text(" pass.").foregroundColor(dimColor)
    }
}
