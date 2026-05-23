import SwiftUI
import PassesCore
import PassesUICore

/// Create-time URI-scheme confirmation gate for a QR `ScannableCard`. Inverts
/// the button prominence relative to `B3UrlConfirmSheet`: Cancel is the focused
/// filled action, Confirm is the lower-emphasis text button. A payload
/// classified as auto-acting cannot land in the wallet without an explicit
/// confirm tap.
///
/// Returns an empty view for `QrPayloadKind.plainText`.
///
/// Mirror of Android's `BarcodeCreateConfirmSheet`.
public struct BarcodeCreateConfirmSheet: View {
    let payloadKind: QrPayloadKind
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(
        payloadKind: QrPayloadKind,
        telemetry: any UiTelemetryGuard,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.payloadKind = payloadKind
        self.telemetry = telemetry
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        if case .plainText = payloadKind {
            EmptyView()
        } else {
            content
        }
    }

    @Environment(\.passesSemantics) private var semantics

    @ViewBuilder
    private var content: some View {
        let emphasis = semantics?.securitySheet
        let kind = Self.barcodeCreateKind(of: payloadKind) ?? .unknownScheme
        VStack(alignment: .leading, spacing: 12) {
            BarcodeCreateBody(payloadKind: payloadKind, emphasis: emphasis)
            HStack(spacing: 12) {
                Spacer()
                Button(Self.confirmText) {
                    telemetry.onBarcodeCreateGateConfirmed(kind: kind)
                    onConfirm()
                }
                .foregroundColor((emphasis?.cancelForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
                Button(Self.cancelText) {
                    telemetry.onBarcodeCreateGateDismissed(kind: kind)
                    onCancel()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill((emphasis?.confirmContainer ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
                )
                .foregroundColor((emphasis?.confirmForeground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((emphasis?.sheetBackground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
        .onAppear {
            telemetry.onBarcodeCreateGateShown(kind: kind)
        }
    }

    private static let confirmText = "Confirm"
    private static let cancelText = "Cancel"

    /// Maps a `QrPayloadKind` to its coarse `BarcodeCreateKind` family for
    /// telemetry. `plainText` returns `nil` (callers short-circuit before this).
    public nonisolated static func barcodeCreateKind(of payloadKind: QrPayloadKind) -> BarcodeCreateKind? {
        switch payloadKind {
        case .plainText: return nil
        case .url: return .url
        case .phone: return .phone
        case .sms: return .sms
        case .mailto: return .mailto
        case .geo: return .geo
        case .wifi: return .wifi
        case .bitcoin: return .bitcoin
        case .ethereum: return .ethereum
        case .magnet: return .magnet
        case .market: return .market
        case .intent: return .intent
        case .unknownScheme: return .unknownScheme
        }
    }
}

private struct BarcodeCreateBody: View {
    let payloadKind: QrPayloadKind
    let emphasis: SecuritySheetStyle?

    var body: some View {
        let message = Self.message(for: payloadKind)
        let verbatim = Self.verbatim(for: payloadKind)
        let isCryptoAddress: Bool = {
            switch payloadKind {
            case .bitcoin, .ethereum: return true
            default: return false
            }
        }()
        Text("Confirm this QR")
            .font(.title2)
            .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
        Text(message)
            .font(.body)
            .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
        if let verbatim {
            VStack(alignment: .leading, spacing: 4) {
                Text(isolated(verbatim))
                    .font(isCryptoAddress ? .body.monospaced() : .body)
                    .foregroundColor((emphasis?.emphasisForeground ?? ArgbColor(argb: 0xFF000000)).swiftUIColor)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill((emphasis?.emphasisBackground ?? ArgbColor(argb: 0xFFEFEFEF)).swiftUIColor)
            )
        }
    }

    /// Per-arm dispatcher for the warning sentence shown above the verbatim
    /// payload. Every `QrPayloadKind` arm is enumerated so adding a new arm in
    /// `passes-core` surfaces as a missing-case compile error.
    static func message(for kind: QrPayloadKind) -> String {
        switch kind {
        case .plainText: return ""
        case .url: return "When scanned, this QR will open a website:"
        case .phone: return "When scanned, this QR will dial:"
        case .sms: return "When scanned, this QR will start a text message to:"
        case .mailto: return "When scanned, this QR will start an email to:"
        case .geo: return "When scanned, this QR will open a map location:"
        case .wifi(let ssid):
            return ssid != nil
                ? "When scanned, this QR will offer to join a wifi network:"
                : "When scanned, this QR will offer to join an unnamed wifi network."
        case .bitcoin: return "When scanned, this QR will request a Bitcoin payment to:"
        case .ethereum: return "When scanned, this QR will request an Ethereum payment to:"
        case .magnet: return "When scanned, this QR will open a torrent magnet link."
        case .market: return "When scanned, this QR will open the Play Store:"
        case .intent: return "When scanned, this QR will launch an Android app intent:"
        case .unknownScheme: return "When scanned, this QR uses an unrecognized scheme:"
        }
    }

    /// Per-arm dispatcher for the verbatim payload string rendered in the
    /// emphasis panel.
    static func verbatim(for kind: QrPayloadKind) -> String? {
        switch kind {
        case .plainText: return nil
        case .url(_, let host, let raw): return host ?? raw
        case .phone(let number): return number
        case .sms(let number): return number
        case .mailto(let address): return address
        case .geo(let coords): return coords
        case .wifi(let ssid): return ssid
        case .bitcoin(let address): return address
        case .ethereum(let address): return address
        case .magnet: return nil
        case .market(let productId): return productId
        case .intent(let raw): return raw
        case .unknownScheme(_, let raw): return raw
        }
    }
}

public extension QrPayloadKind {
    /// Whether `BarcodeCreateConfirmSheet` should be invoked. Returns false
    /// only for `plainText`.
    var requiresCreateConfirmation: Bool {
        if case .plainText = self { return false }
        return true
    }
}
