import SwiftUI
import PassesCore

/// Renders the back of a pass: the list of `Pass.backFields`, with detected
/// URLs, phone numbers, and email addresses rendered as tappable affordances.
/// Tapping fires the matching callback with the parsed `SecurityIntent`;
/// PassesUI never invokes the host's outbound action directly.
///
/// The three callbacks are not defaulted - see ADR 0003 D5. A host that forgets
/// to wire one is a compile error, not a runtime swallow.
///
/// Mirror of Android's `is.walt.passes.ui.PassBack`.
public struct PassBack: View {
    let pass: Pass
    let onUrlIntent: (B3UrlIntent) -> Void
    let onPhoneIntent: (PhoneIntent) -> Void
    let onEmailIntent: (EmailIntent) -> Void
    let telemetry: any UiTelemetryGuard
    let locale: PassLocale

    public init(
        pass: Pass,
        onUrlIntent: @escaping (B3UrlIntent) -> Void,
        onPhoneIntent: @escaping (PhoneIntent) -> Void,
        onEmailIntent: @escaping (EmailIntent) -> Void,
        telemetry: any UiTelemetryGuard,
        locale: PassLocale = PassLocale("en")
    ) {
        self.pass = pass
        self.onUrlIntent = onUrlIntent
        self.onPhoneIntent = onPhoneIntent
        self.onEmailIntent = onEmailIntent
        self.telemetry = telemetry
        self.locale = locale
    }

    public var body: some View {
        let strings = pass.resolveLocalizedStrings(preferred: locale)
        let displayOrg = strings.lookupOrSelf(pass.organizationName)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(pass.backFields.enumerated()), id: \.offset) { _, field in
                BackFieldRow(
                    field: field,
                    organizationName: displayOrg,
                    strings: strings,
                    onUrlIntent: onUrlIntent,
                    onPhoneIntent: onPhoneIntent,
                    onEmailIntent: onEmailIntent
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            telemetry.onPassBackOpened(type: pass.type)
        }
    }
}

private struct BackFieldRow: View {
    let field: PassField
    let organizationName: String
    let strings: LocalizedStrings
    let onUrlIntent: (B3UrlIntent) -> Void
    let onPhoneIntent: (PhoneIntent) -> Void
    let onEmailIntent: (EmailIntent) -> Void

    var body: some View {
        let displayLabel = strings.lookupOrSelf(field.label)
        let displayValue = strings.lookupOrSelf(field.value)
        let source = SourceField(
            fieldKey: field.key,
            fieldLabel: displayLabel,
            organizationName: organizationName
        )
        let spans = FieldLinkScanner.scan(displayValue, source: source)
        VStack(alignment: .leading, spacing: 4) {
            if let lbl = displayLabel, !lbl.isEmpty {
                Text(lbl)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if spans.isEmpty {
                Text(displayValue)
                    .font(.body)
            } else {
                BackFieldClickableText(
                    text: displayValue,
                    spans: spans,
                    onUrlIntent: onUrlIntent,
                    onPhoneIntent: onPhoneIntent,
                    onEmailIntent: onEmailIntent
                )
            }
        }
    }
}

/// SwiftUI does not ship a direct equivalent of Compose's `ClickableText` (per-
/// offset click handler with annotated spans). Render the text via
/// `AttributedString`, wrapping link substrings in `.link` attributes whose
/// scheme encodes the intent index; `Environment.openURL` is intercepted so
/// taps surface as the matching `SecurityIntent` callback rather than opening
/// an external app. See `docs/adr/passes-ui-3.md`.
private struct BackFieldClickableText: View {
    let text: String
    let spans: [LinkSpan]
    let onUrlIntent: (B3UrlIntent) -> Void
    let onPhoneIntent: (PhoneIntent) -> Void
    let onEmailIntent: (EmailIntent) -> Void

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "x-walt-passes-ui",
                      let idx = Int(url.host ?? ""),
                      idx >= 0, idx < spans.count else {
                    return .systemAction
                }
                switch spans[idx].intent {
                case .url(let i): onUrlIntent(i)
                case .phone(let i): onPhoneIntent(i)
                case .email(let i): onEmailIntent(i)
                }
                return .handled
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let ns = text as NSString
        for (i, span) in spans.enumerated() {
            let nsRange = NSRange(location: span.start, length: span.endExclusive - span.start)
            guard
                nsRange.location + nsRange.length <= ns.length,
                let stringRange = Range(nsRange, in: text),
                let attrRange = result.range(of: String(text[stringRange]))
            else { continue }
            if let linkURL = URL(string: "x-walt-passes-ui://\(i)") {
                result[attrRange].link = linkURL
            }
            result[attrRange].underlineStyle = .single
            result[attrRange].font = .body.weight(.medium)
        }
        return result
    }
}
