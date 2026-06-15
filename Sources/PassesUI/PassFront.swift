import SwiftUI
import PassesCore
import PassesUICore

/// Renders the front of a pass. Layout switches on `Pass.type` (boarding pass,
/// event ticket, generic/coupon/store-card). Mirror of Android's
/// `is.walt.passes.ui.PassFront`.
///
/// The signature trust badge and (when applicable) the expired overlay default
/// to always-on. `showSignatureBadge` and `showExpiredOverlay` are the bounded
/// host opt-outs (ADR 0003 D5); a host that opts out must disclose the
/// equivalent signal in its own chrome.
public struct PassFront: View {
    let pass: Pass
    let signatureStatus: SignatureStatus
    let telemetry: any UiTelemetryGuard
    let locale: PassLocale
    let userLabel: String?
    let nowEpochMillis: Int64
    let showSignatureBadge: Bool
    let showExpiredOverlay: Bool

    public init(
        pass: Pass,
        signatureStatus: SignatureStatus,
        telemetry: any UiTelemetryGuard,
        locale: PassLocale = PassLocale("en"),
        userLabel: String? = nil,
        nowEpochMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        showSignatureBadge: Bool = true,
        showExpiredOverlay: Bool = true
    ) {
        self.pass = pass
        self.signatureStatus = signatureStatus
        self.telemetry = telemetry
        self.locale = locale
        self.userLabel = userLabel
        self.nowEpochMillis = nowEpochMillis
        self.showSignatureBadge = showSignatureBadge
        self.showExpiredOverlay = showExpiredOverlay
    }

    public var body: some View {
        let band = signatureStatus.band
        let strings = pass.resolveLocalizedStrings(preferred: locale)
        let expired = ExpiredOverlayState.from(pass: pass, nowEpochMillis: nowEpochMillis)
        ZStack {
            PassFrontSurface(
                pass: pass,
                band: band,
                strings: strings,
                userLabel: userLabel,
                locale: locale,
                showSignatureBadge: showSignatureBadge
            )
            if showExpiredOverlay {
                if case .none = expired {
                    EmptyView()
                } else {
                    ExpiredOverlay(state: expired)
                }
            }
        }
        .onAppear {
            telemetry.onPassRendered(type: pass.type, signatureBand: band)
        }
    }
}

private struct PassFrontSurface: View {
    let pass: Pass
    let band: SignatureBand
    let strings: LocalizedStrings
    let userLabel: String?
    let locale: PassLocale
    let showSignatureBadge: Bool

    var body: some View {
        let bg = pass.colors.background.swiftUIColorOrDefault(.gray.opacity(0.1))
        let fg = pass.colors.foreground.swiftUIColorOrDefault(.primary)
        let lbl = pass.colors.label.swiftUIColorOrDefault(fg.opacity(0.7))
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                // The front-of-card eyebrow routes through PassIdentityBlock so the
                // trust-caption rule is enforced by the same view every surface uses.
                PassIdentityBlock(pass: pass, userLabel: userLabel, locale: locale, primaryColor: lbl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showSignatureBadge {
                    SignatureTrustBadge(band: band)
                }
            }
            switch pass.type {
            case .boardingPass:
                BoardingPassBody(fields: pass.frontFields, strings: strings, foreground: fg, label: lbl)
            case .eventTicket:
                EventTicketBody(fields: pass.frontFields, strings: strings, foreground: fg, label: lbl)
            case .coupon, .storeCard, .generic:
                GenericBody(fields: pass.frontFields, strings: strings, foreground: fg, label: lbl)
            }
            if let barcode = pass.barcode {
                HStack {
                    Spacer()
                    BarcodeView(barcode: barcode)
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(bg)
        )
        .foregroundColor(fg)
    }
}

private struct BoardingPassBody: View {
    let fields: PassFields
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color

    var body: some View {
        HeaderRow(fields: fields.header, strings: strings, foreground: foreground, label: label)
        HStack {
            ForEach(Array(fields.primary.prefix(2).enumerated()), id: \.offset) { index, field in
                FieldCell(
                    field: field,
                    strings: strings,
                    foreground: foreground,
                    label: label,
                    style: .primary,
                    align: index == 1 ? .trailing : .leading
                )
                .frame(maxWidth: .infinity, alignment: index == 1 ? .trailing : .leading)
            }
        }
        SecondaryRow(fields: fields.secondary, strings: strings, foreground: foreground, label: label)
        if !fields.auxiliary.isEmpty {
            SecondaryRow(fields: fields.auxiliary, strings: strings, foreground: foreground, label: label)
        }
    }
}

private struct EventTicketBody: View {
    let fields: PassFields
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color

    var body: some View {
        HeaderRow(fields: fields.header, strings: strings, foreground: foreground, label: label)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(fields.primary.enumerated()), id: \.offset) { _, field in
                FieldCell(field: field, strings: strings, foreground: foreground, label: label, style: .primary)
            }
        }
        SecondaryRow(fields: fields.secondary, strings: strings, foreground: foreground, label: label)
    }
}

private struct GenericBody: View {
    let fields: PassFields
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color

    var body: some View {
        HeaderRow(fields: fields.header, strings: strings, foreground: foreground, label: label)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(fields.primary.enumerated()), id: \.offset) { _, field in
                FieldCell(field: field, strings: strings, foreground: foreground, label: label, style: .primary)
            }
        }
        SecondaryRow(fields: fields.secondary, strings: strings, foreground: foreground, label: label)
        if !fields.auxiliary.isEmpty {
            SecondaryRow(fields: fields.auxiliary, strings: strings, foreground: foreground, label: label)
        }
    }
}

private struct HeaderRow: View {
    let fields: [PassField]
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color

    var body: some View {
        if !fields.isEmpty {
            HStack(spacing: 16) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    FieldCell(field: field, strings: strings, foreground: foreground, label: label, style: .header)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct SecondaryRow: View {
    let fields: [PassField]
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color

    var body: some View {
        if !fields.isEmpty {
            HStack(spacing: 16) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    FieldCell(field: field, strings: strings, foreground: foreground, label: label, style: .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private enum FieldCellStyle {
    case header
    case primary
    case secondary
}

private struct FieldCell: View {
    let field: PassField
    let strings: LocalizedStrings
    let foreground: Color
    let label: Color
    let style: FieldCellStyle
    var align: HorizontalAlignment = .leading

    var body: some View {
        let displayLabel = strings.lookupOrSelf(field.label)
        let displayValue = strings.lookupOrSelf(field.value)
        let textAlignment: SwiftUI.TextAlignment = {
            switch field.textAlignment {
            case .left, .natural: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }()
        VStack(alignment: align, spacing: 2) {
            if let lbl = displayLabel, !lbl.isEmpty {
                Text(lbl)
                    .font(.caption2)
                    .foregroundColor(label)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: .infinity, alignment: alignmentFor(textAlignment))
            }
            Text(displayValue)
                .font(valueFont)
                .foregroundColor(foreground)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: alignmentFor(textAlignment))
        }
    }

    private var valueFont: Font {
        switch style {
        case .header: return .title3
        case .primary: return .title
        case .secondary: return .body
        }
    }

    private func alignmentFor(_ t: SwiftUI.TextAlignment) -> Alignment {
        switch t {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct SignatureTrustBadge: View {
    let band: SignatureBand
    @Environment(\.passesSemantics) private var semantics

    var body: some View {
        let badge = semantics?.signatureBadge
        let (bg, fg, copy): (Color, Color, String) = {
            switch band {
            case .untrusted:
                return (
                    (badge?.unsignedBackground ?? ArgbColor(argb: 0xFFFFE0E0)).swiftUIColor,
                    (badge?.unsignedForeground ?? ArgbColor(argb: 0xFF101010)).swiftUIColor,
                    "Unsigned"
                )
            case .selfSigned:
                return (
                    (badge?.selfSignedBackground ?? ArgbColor(argb: 0xFFFFF0E0)).swiftUIColor,
                    (badge?.selfSignedForeground ?? ArgbColor(argb: 0xFF101010)).swiftUIColor,
                    "Self-signed"
                )
            case .appleVerified:
                return (
                    (badge?.appleVerifiedBackground ?? ArgbColor(argb: 0xFFE0FFE0)).swiftUIColor,
                    (badge?.appleVerifiedForeground ?? ArgbColor(argb: 0xFF101010)).swiftUIColor,
                    "Verified"
                )
            case .incomplete:
                return (
                    (badge?.certChainIncompleteBackground ?? ArgbColor(argb: 0xFFFFFFE0)).swiftUIColor,
                    (badge?.certChainIncompleteForeground ?? ArgbColor(argb: 0xFF101010)).swiftUIColor,
                    "Signature unknown"
                )
            }
        }()
        Text(copy)
            .font(.caption2)
            .foregroundColor(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }
}

internal extension Optional where Wrapped == ColorValue {
    func swiftUIColorOrDefault(_ fallback: Color) -> Color {
        guard let v = self else { return fallback }
        let packed = UInt32(bitPattern: v.rgb) & 0xFFFFFF
        let r = Double((packed >> 16) & 0xFF) / 255.0
        let g = Double((packed >> 8) & 0xFF) / 255.0
        let b = Double(packed & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
