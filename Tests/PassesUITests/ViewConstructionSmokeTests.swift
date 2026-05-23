import Testing
import SwiftUI
import PassesCore

@testable import PassesUI

/// Compile-time + cheap-runtime smoke tests for every public view. Equivalent
/// to Android's `ComposableSurfaceLockTest`: builds the view and verifies its
/// type is the documented one. Catches accidental signature changes (e.g. an
/// added unconditional parameter) at build time.
@MainActor
@Suite("View construction smoke")
struct ViewConstructionSmokeTests {

    private static let source = SourceField(
        fieldKey: "k",
        fieldLabel: "Label",
        organizationName: "Org"
    )

    private static func makePass() -> Pass {
        Pass(
            type: .generic,
            serialNumber: "0",
            description: "fixture",
            organizationName: "Org",
            colors: PassColors(
                foreground: ColorValue(rgb: 0),
                background: ColorValue(rgb: 0xFFFFFF),
                label: ColorValue(rgb: 0x444444)
            ),
            frontFields: PassFields(
                primary: [PassField(key: "p", label: nil, value: "value")]
            ),
            backFields: []
        )
    }

    @Test func passFrontConstructsWithDefaults() {
        let v = PassFront(
            pass: Self.makePass(),
            signatureStatus: .selfSigned,
            telemetry: NoopUiTelemetryGuard()
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func passBackConstructsWithRequiredCallbacks() {
        let v = PassBack(
            pass: Self.makePass(),
            onUrlIntent: { _ in },
            onPhoneIntent: { _ in },
            onEmailIntent: { _ in },
            telemetry: NoopUiTelemetryGuard()
        )
        #expect(type(of: v.body) != Never.self)
    }

    @Test func expiredOverlayConstructsForEveryState() {
        _ = ExpiredOverlay(state: .none)
        _ = ExpiredOverlay(state: .voided)
        _ = ExpiredOverlay(state: .expired(at: PassInstant(epochMillis: 0)))
    }

    @Test func b3UrlConfirmSheetConstructsWithDefaults() {
        let intent = B3UrlIntent(url: "https://x.example", sourceField: Self.source)
        _ = B3UrlConfirmSheet(
            intent: intent,
            passType: .generic,
            telemetry: NoopUiTelemetryGuard(),
            onConfirm: {},
            onDismiss: {}
        )
    }

    @Test func phoneConfirmSheetConstructsWithDomainHero() {
        let intent = PhoneIntent(phoneNumber: "+15551234567", sourceField: Self.source)
        _ = PhoneConfirmSheet(
            intent: intent,
            passType: .eventTicket,
            telemetry: NoopUiTelemetryGuard(),
            onConfirm: {},
            onDismiss: {},
            emphasisStyle: .domainHero
        )
    }

    @Test func emailConfirmSheetConstructsWithDomainHero() {
        let intent = EmailIntent(emailAddress: "x@y.example", sourceField: Self.source)
        _ = EmailConfirmSheet(
            intent: intent,
            passType: .boardingPass,
            telemetry: NoopUiTelemetryGuard(),
            onConfirm: {},
            onDismiss: {},
            emphasisStyle: .domainHero
        )
    }

    @Test func passImportConfirmConstructs() {
        _ = PassImportConfirm(
            pass: Self.makePass(),
            signatureStatus: .selfSigned,
            telemetry: NoopUiTelemetryGuard(),
            onConfirm: {},
            onDismiss: {}
        )
    }

    @Test func barcodeCreateConfirmSheetConstructs() {
        _ = BarcodeCreateConfirmSheet(
            payloadKind: .url(scheme: "https", host: "x", raw: "https://x"),
            telemetry: NoopUiTelemetryGuard(),
            onConfirm: {},
            onCancel: {}
        )
    }

    @Test func scannableCardTileAndScreenConstruct() {
        let input = ScannableCardCreateInput(
            payload: "QR payload",
            format: .qr,
            label: "Loyalty"
        )
        let result = ScannableCardInputValidator.validate(
            input: input,
            id: ScannableCardId("card-1"),
            createdAt: PassInstant(epochMillis: 0)
        )
        guard case .success(let card) = result else {
            Issue.record("validator should accept fixture input: \(result)")
            return
        }
        _ = ScannableCardTile(card: card, onTap: {})
        _ = ScannableCardScreen(card: card)
        _ = ScannableCardView(card: card)
        _ = ScannableCardRowTile(card: card, onTap: {})
    }
}
