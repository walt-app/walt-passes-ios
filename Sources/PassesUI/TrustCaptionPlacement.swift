import Foundation

/// Where the trust/provenance signal is carried on a `ScannableCard` detail surface
/// (`ScannableCardScreen`). This is the kernel's answer to "let me fold the provenance
/// signal into my own details section" (wpass-gv6 / Walt wlt-3cer).
///
///  - `docked` — the kernel renders the verbatim non-suppressible
///    `ScannableCardTrustCaption` ("Created by you") docked at the bottom of the surface.
///    This is the default; every existing caller is unchanged.
///  - `hostedTypeRow` — the kernel renders **no** trust caption on the detail surface. The
///    host carries the provenance claim itself, as a single "Pass type" row inside its own
///    details section (for a scannable card the value is "Scanned"). Under this mode a
///    neutral type label is an accepted carrier of the claim, and the row MAY sit inside a
///    collapsed-by-default foldout — it is **not** required to be always-visible.
///
/// `hostedTypeRow` is a deliberate C2 policy concession, not the earlier "relocate the
/// verbatim caption" contract: it lets the host drop the kernel caption entirely and
/// represent provenance with its own type label. The reasoning, the residual risk, and the
/// bound are recorded in `SCANNABLE_CARD_THREAT_MODEL.md` (C2 — host "Pass type" row
/// concession). The kernel cannot enforce that the host actually renders the row, so the
/// obligation is pinned consumer-side by a walt-ios test that the details section renders
/// a "Pass type" row enumerating the artifact class — NOT (as before) that the host
/// mounts the kernel caption.
///
/// The artifact-class distinction at the surface where it matters most — the wallet list —
/// is unaffected: C1 (distinct lane / no signature dot / no verified band) still holds, and
/// the detail surface is reached only after that list-level distinction. That is what makes
/// dropping the detail-surface caption a bounded trade rather than an open suppression hole.
///
/// Mirror of Android's `is.walt.passes.ui.TrustCaptionPlacement`.
public enum TrustCaptionPlacement: Sendable {
    /// Kernel renders the verbatim caption docked at the bottom of the surface (default).
    case docked

    /// Kernel renders no caption; the host carries provenance via its own "Pass type" row
    /// (a neutral type label is an accepted carrier, and the row may be collapsed by
    /// default). C2 concession — see the type doc and `SCANNABLE_CARD_THREAT_MODEL.md`.
    case hostedTypeRow
}
