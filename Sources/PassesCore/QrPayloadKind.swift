import Foundation

/// Classification of a QR code's payload string by its URI scheme (or absence thereof).
///
/// Surface for the create-time preview dialog (sibling wpass-lzi.9): when a user enters a
/// QR payload, the consumer UI shows what a future scanner phone would interpret it as so
/// the user can confirm intent before saving the card. The classification is *advisory* —
/// Walt does not block any payload here. The downstream validator (wpass-lzi.4) rejects
/// structural hazards (bidi controls, length overruns); this classifier assumes a payload
/// that has already cleared that bar.
///
/// Trust posture per arm:
///
///  - `plainText`: nothing happens on scan beyond display. Lowest risk.
///  - `url`: third-party scanner phone's browser will offer to open. Phishing / drive-by
///    download risk on the recipient device.
///  - `phone` / `sms`: dialer / messaging app opens, pre-filled. Premium-rate dial fraud risk.
///  - `mailto`: mail app opens with recipient pre-filled.
///  - `geo`: maps app opens at coordinates.
///  - `wifi`: phone offers to join network. Note: password is parsed out of the source string
///    but deliberately NOT carried in this kind — see `wifi` for rationale.
///  - `bitcoin` / `ethereum`: crypto wallet apps may auto-send. Address-substitution attack risk.
///  - `magnet`: torrent client may auto-add.
///  - `market`: Play Store opens a listing.
///  - `intent`: arbitrary Android intent URI. Most dangerous — can target named components,
///    pass extras, bypass user-visible scheme prompts. Walt surfaces these as "Android intent"
///    with no further dissection.
///  - `unknownScheme`: scheme matches RFC 3986 syntax but is not in the recognized roster.
public enum QrPayloadKind: Sendable, Equatable {
    /// No URI scheme detected. The QR holds opaque text.
    case plainText

    /// `http` or `https` URL. `host` may be null even on URIs that parse cleanly (e.g. a
    /// scheme-only string like `http://`). `raw` preserves the original string verbatim —
    /// no normalization, no IDN conversion, no Punycode unwrapping — so the preview UI shows
    /// the user exactly what a future scanner would receive.
    case url(scheme: String, host: String?, raw: String)

    /// `tel:` payload. `number` is the raw substring after the scheme.
    case phone(number: String)

    /// `sms:` payload. `number` is the raw substring after the scheme, stripped of any `?` query tail.
    case sms(number: String)

    /// `mailto:` payload. `address` is the raw substring after the scheme, stripped of any `?` query tail.
    case mailto(address: String)

    /// `geo:` payload. `coords` is the raw substring after the scheme.
    case geo(coords: String)

    /// `WIFI:` payload. `ssid` is the network name; null if the payload omits the `S:` field.
    ///
    /// CRITICAL: the password field (`P:`) is deliberately NOT modeled here even though it
    /// is present in the source string. The classifier output flows to a preview dialog
    /// the user might screenshot, copy, or share. Surfacing the password through this
    /// data class would let it leak into UI state, screenshots, accessibility tree, and
    /// any telemetry that flattens kind instances. Parsing-and-dropping is a trust choice:
    /// the user already knows their own wifi password if they typed this in; the scanner
    /// recipient is the one who needs the password, and they get it from the QR — not from
    /// Walt's preview surface.
    case wifi(ssid: String?)

    /// `bitcoin:` payment URI. `address` is the bare address, with any `?amount=...` tail stripped.
    case bitcoin(address: String)

    /// `ethereum:` payment URI. `address` is the bare address, with any `?value=...` tail stripped.
    case ethereum(address: String)

    /// `magnet:` torrent link. Raw payload not surfaced — the magnet xt hash is rarely user-meaningful.
    case magnet

    /// Android Play Store URI (`market:` or `market://`). `productId` is whatever follows
    /// the scheme (typically `details?id=com.example`).
    case market(productId: String)

    /// Android intent URI (`intent:`). Carries `raw` — these URIs are too dangerous to
    /// dissect in the preview surface. The user gets a generic "Android intent" warning
    /// and the verbatim string; pretending to parse a structured shape would invite
    /// mis-classification.
    case intent(raw: String)

    /// Some other RFC 3986 scheme. The user should see both `scheme` and `raw`.
    case unknownScheme(scheme: String, raw: String)
}
