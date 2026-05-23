import Foundation
import PassesCore

/// PII-disciplined telemetry surface for `PassesUI`. Mirror of Android's
/// `is.walt.passes.ui.UiTelemetryGuard`. Every method takes enums and primitives
/// only - never free-form strings or `Pass` / `PassField` instances. Adding a
/// String / Pass / PassField parameter to any method below is a security-policy
/// change.
public protocol UiTelemetryGuard: Sendable {
    func onPassRendered(type: PassType, signatureBand: SignatureBand)
    func onPassBackOpened(type: PassType)
    func onSecuritySheetShown(intentKind: SecurityIntentKind, type: PassType)
    func onSecuritySheetConfirmed(intentKind: SecurityIntentKind, type: PassType)
    func onSecuritySheetDismissed(intentKind: SecurityIntentKind, type: PassType)
    func onImageDecodeRejected(reason: ImageDecodeRejection)
    func onImportConfirmShown(type: PassType, signatureBand: SignatureBand)
    func onImportConfirmed(type: PassType, signatureBand: SignatureBand)
    func onImportDismissed(type: PassType, signatureBand: SignatureBand)
    func onBarcodeCreateGateShown(kind: BarcodeCreateKind)
    func onBarcodeCreateGateConfirmed(kind: BarcodeCreateKind)
    func onBarcodeCreateGateDismissed(kind: BarcodeCreateKind)
}

/// Coarse trust band derived from `SignatureStatusKind`. Lives in the UI module
/// because the band is what the UI displays.
public enum SignatureBand: Sendable, CaseIterable {
    case untrusted
    case selfSigned
    case appleVerified
    case incomplete
}

/// Which of the three security intent families opened a sheet.
public enum SecurityIntentKind: Sendable, CaseIterable {
    case url
    case phone
    case email
}

/// Coarse family of the QR payload classified by `QrPayloadKind`. Mirrors the
/// Android `BarcodeCreateKind` enum 1:1.
public enum BarcodeCreateKind: Sendable, CaseIterable {
    case url
    case phone
    case sms
    case mailto
    case geo
    case wifi
    case bitcoin
    case ethereum
    case magnet
    case market
    case intent
    case unknownScheme
}

/// Why an image-decode attempt was refused.
public enum ImageDecodeRejection: Sendable, CaseIterable {
    case exceedsWidth
    case exceedsHeight
    case exceedsArea
    case malformed
    case other
}

/// No-op default for hosts that have not yet wired a guard.
public struct NoopUiTelemetryGuard: UiTelemetryGuard {
    public init() {}
    public func onPassRendered(type: PassType, signatureBand: SignatureBand) {}
    public func onPassBackOpened(type: PassType) {}
    public func onSecuritySheetShown(intentKind: SecurityIntentKind, type: PassType) {}
    public func onSecuritySheetConfirmed(intentKind: SecurityIntentKind, type: PassType) {}
    public func onSecuritySheetDismissed(intentKind: SecurityIntentKind, type: PassType) {}
    public func onImageDecodeRejected(reason: ImageDecodeRejection) {}
    public func onImportConfirmShown(type: PassType, signatureBand: SignatureBand) {}
    public func onImportConfirmed(type: PassType, signatureBand: SignatureBand) {}
    public func onImportDismissed(type: PassType, signatureBand: SignatureBand) {}
    public func onBarcodeCreateGateShown(kind: BarcodeCreateKind) {}
    public func onBarcodeCreateGateConfirmed(kind: BarcodeCreateKind) {}
    public func onBarcodeCreateGateDismissed(kind: BarcodeCreateKind) {}
}

extension SignatureStatus {
    /// Map a `passes-core` `SignatureStatus` to its UI-facing `SignatureBand`.
    /// Mirror of Android's internal `SignatureStatus.toBand()`.
    var band: SignatureBand {
        switch self {
        case .unsigned: return .untrusted
        case .selfSigned: return .selfSigned
        case .appleVerified: return .appleVerified
        case .certChainIncomplete: return .incomplete
        }
    }
}
