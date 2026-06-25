import PassesCore
import PassesUICore
import SwiftUI

/// Trust-claim-bearing confirmation surface for the in-app PKPASS import flow.
/// The user sees the parsed pass exactly as Walt will store it - preview
/// rendered through `PassFront`, signature trust band captioned in plain copy -
/// before they tap Save. Tapping Cancel discards.
///
/// Mirror of Android's `is.walt.passes.ui.PassImportConfirm`. iOS does not have
/// a system back-press dispatcher that mirrors Android's; the cancel button is
/// the sole dismissal path here. See `docs/adr/passes-ui-4.md`.
public struct PassImportConfirm: View {
    let pass: Pass
    let signatureStatus: SignatureStatus
    let telemetry: any UiTelemetryGuard
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let locale: PassLocale

    @Environment(\.passesSemantics) private var semantics

    public init(
        pass: Pass,
        signatureStatus: SignatureStatus,
        telemetry: any UiTelemetryGuard,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        locale: PassLocale = PassLocale("en")
    ) {
        self.pass = pass
        self.signatureStatus = signatureStatus
        self.telemetry = telemetry
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.locale = locale
    }

    public var body: some View {
        let band = signatureStatus.band
        let emphasis = semantics?.securitySheet
        VStack(alignment: .leading, spacing: 16) {
            Text("Add this pass?")
                .font(.title2)
                .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            ImportTrustCaption(band: band)
            PassFront(
                pass: pass,
                signatureStatus: signatureStatus,
                telemetry: telemetry,
                locale: locale
            )
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    telemetry.onImportDismissed(type: pass.type, signatureBand: band)
                    onDismiss()
                }
                .foregroundColor((emphasis?.cancelForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
                Button("Save pass") {
                    telemetry.onImportConfirmed(type: pass.type, signatureBand: band)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            telemetry.onImportConfirmShown(type: pass.type, signatureBand: band)
        }
    }
}

private struct ImportTrustCaption: View {
    let band: SignatureBand
    @Environment(\.passesSemantics) private var semantics

    var body: some View {
        let emphasis = semantics?.securitySheet
        let (title, body): (String, String) = {
            switch band {
            case .appleVerified:
                return (
                    "Verified Apple issuer",
                    "Walt verified this pass's signature against Apple's issuer chain."
                )
            case .selfSigned:
                return (
                    "Self-signed issuer",
                    "The signature is valid but Walt cannot verify who issued this pass."
                )
            case .incomplete:
                return (
                    "Issuer chain incomplete",
                    "The pass is signed but Walt could not complete the issuer chain."
                )
            case .untrusted:
                return (
                    "No signature",
                    "This pass is unsigned. Walt cannot verify who created it."
                )
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundColor((emphasis?.emphasisForeground ?? ArgbColor(argb: 0xFF000000)).swiftUIColor)
            Text(body)
                .font(.body)
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
