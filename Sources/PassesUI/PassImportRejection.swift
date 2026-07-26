import PassesCore
import PassesUICore
import SwiftUI

/// Trust-claim-bearing rejection sheet shown when an in-app pass import fails. Used
/// after the host's `PassParser.parse` returned `ParseResult.tampered`, `.malformed`,
/// or `.unsupported`. The sheet's copy is the user-facing trust message the host
/// cannot reimplement: a future refactor that swapped this for a generic toast would
/// silently drop the "we detected tampering" disclosure.
///
/// The four `ParseFailureKind` arms map to four distinct messages — collapsing them
/// defeats the lenient-with-disclosure signature policy (decision-wlt-0tn-q1 1a). A
/// tampered pass is a security event; a malformed file is not. The user must see the
/// difference.
///
/// The sheet is dismiss-only: there is no Save / Open / Anyway button. Tampered,
/// malformed, unsupported, and resource-limit failures are all unconditional
/// rejections at v1; ADR 0001's parser-hardening posture is "fail closed and explain."
///
/// Mirror of Android's `PassImportRejectionSheet` (passes-ui wpass-9bs).
public struct PassImportRejectionSheet: View {
    let kind: ParseFailureKind
    let telemetry: any UiTelemetryGuard
    let onDismiss: () -> Void

    public init(
        kind: ParseFailureKind,
        telemetry: any UiTelemetryGuard,
        onDismiss: @escaping () -> Void
    ) {
        self.kind = kind
        self.telemetry = telemetry
        self.onDismiss = onDismiss
    }

    @Environment(\.passesSemantics) private var semantics

    public var body: some View {
        let emphasis = semantics?.securitySheet
        let copy = Self.rejectionCopy(kind)
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.title)
                .font(.title2)
                .foregroundColor((emphasis?.bodyForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.body)
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
                Button("Close", action: onDismiss)
                    .foregroundColor((emphasis?.cancelForeground ?? ArgbColor(argb: 0xFF202020)).swiftUIColor)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((emphasis?.sheetBackground ?? ArgbColor(argb: 0xFFFFFFFF)).swiftUIColor)
        .onAppear {
            telemetry.onImportRejected(kind: kind)
        }
    }

    struct RejectionCopy: Equatable {
        let title: String
        let body: String
    }

    /// Per-arm copy table. Every `ParseFailureKind` arm is enumerated so adding a
    /// new arm in `passes-core` surfaces as a missing-case compile error here.
    /// Strings mirror Android's `rejectionCopy` verbatim.
    nonisolated static func rejectionCopy(_ kind: ParseFailureKind) -> RejectionCopy {
        switch kind {
        case .tampered:
            return RejectionCopy(
                title: "This pass appears to have been tampered with",
                body: "The signature does not match the file's contents. Walt did not save this pass."
            )
        case .malformed:
            return RejectionCopy(
                title: "This file is not a valid pass",
                body: "Walt could not read this file as a PKPASS archive."
            )
        case .unsupported:
            return RejectionCopy(
                title: "Walt cannot open this pass",
                body: "This pass uses a format Walt does not support."
            )
        case .resourceLimitExceeded:
            return RejectionCopy(
                title: "This pass is too large to open safely",
                body: "The pass exceeded Walt's safety limits and was not loaded."
            )
        }
    }
}
