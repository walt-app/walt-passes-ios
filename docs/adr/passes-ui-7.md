# passes-ui-7: Colour carries no trust meaning; the wallet-row concession is withdrawn (ios-pjs.2)

iOS anchor for Android's wpass-80y.3/.4 threat-model revisions (walt-passes-android #205 / #208). `SCANNABLE_CARD_THREAT_MODEL.md` remains canonical in the Android kernel repo; iOS sources cite it by name, passes-ui-6 anchors the earlier redesign rows, and this ADR anchors the colour-system rows that partly supersede them.

## Colour carries no trust meaning, for any class

The consumer's 26.08.08 revision (consumer epic ios-pjs; Android wlt-38v8) decouples card colour from the issuer entirely. Its rules, verbatim from the Android row: colour means class, nothing else; the pass file's `backgroundColor` is read, never rendered; card stock is identical in light and dark; no previews on list cards; expired washes out instead of tinting; any item is user-reassignable from Details > Color; no card presents as verified - signature is stated in words, on detail.

Three changes matter to the kernel record. Colour is (a) decoupled from the issuer, so every pkpass renders its class tint regardless of `pass.json` `backgroundColor` (parsed, never rendered at that surface); (b) applied to every artifact class, so documents and scannables carry a tint where passes-ui-6's neutral-surface posture previously forbade one; and (c) user-reassignable per item, so any artifact can carry any of the seven palette colours.

**The verified-band confusion class (C1/C2) stays closed, from new premises:**

1. **No surface presents as verified.** No list card of any class renders a signature affordance, and no card face carries one at detail scale. There is no verified visual for a user-created card to imitate.
2. **Signature status is stated in words, on the detail surface only.** Text, not chrome, so it cannot be imitated by a colour choice.
3. **Colour is uniform per class by default and user-reassignable.** A Bronze PDF or a Teal pkpass is a user preference - not a violation, not a spoof, and nothing may be inferred from it. Colour any user can reassign at will cannot encode provenance even accidentally.

**What this means at the kernel surface.** `ScannableCardScreen(faceTint:)` and `DocumentView(faceTint:)` (ios-pjs.1, wpass-80y.1/.2 mirrors) exist so the consumer can tint the card face without reimplementing these surfaces. Both are presentation-only and bounded the same way:

- The tint reaches the card face only; the panel behind a code stays literally white in both themes and the rasterised page renders identically tinted or not.
- Neither parameter can suppress the barcode, the payload readback, or the trust caption (the C2 note): `faceTint` is not a second route to the C2 bypass the `HostedTypeRow` concession audits. Pinned by `ScannableCardFaceTintTests`.
- Ink on a tinted face derives from the tint's luminance at >= 4.5:1, so the in-words provenance signal cannot be tuned away by a hostile or careless tint.
- **The kernel stores no colour.** No `ScannableCard` or `Document` model or storage column carries one; which colour an item wears is consumer state (walt-ios `WalletColorRepository`), so the kernel never learns why a colour was chosen.
- Both arms decide "is this a tint" through the one shared `faceIsTinted` predicate (`PassesUICore.FaceTint`, wpass-80y.5 mirror), pinned by `FaceTintTests`, so a fully transparent tint falls back to the documented untinted default on either arm.

**Bound of this row (amendment territory, not a PR):** deriving a colour from signature status, verification outcome, or issuer identity anywhere in the kernel; re-adding a colour field to a kernel artifact model or storage table; or a `faceTint` reaching the code panel or the page render.

## Wallet-row concession: WITHDRAWN (ios-pjs.2, 2026-08-18)

The Android C1/C2 wallet-row concession permitted `ScannableCardRowTile` - a flat label-led row for hosts interleaving scannable cards with passes/PDFs in one homogeneous list - under three conditions: no signature affordance on the row, no leading strip styled to read as a verified-pass band, and a detail surface retaining the non-suppressible caption.

**The concession is withdrawn because the surface it permitted no longer exists.** `ScannableCardRowTile` is deleted from `PassesUI` along with its `leadingSlot` hook and its smoke-test construction. Walt renders `StackScannableCardFace` in a stacked deck of class-tinted card faces, and no consumer composed the row tile at the point of deletion. A trust-reasoned surface nothing ships is a liability in an audit trail: it invites a future contributor to adopt it on the strength of a concession argued for a list shape that is gone.

Two things this withdrawal is not: it is not a finding that the row shape was unsafe (conditions 1 and 3 held for its whole life), and it is not a statement about colour - condition 2's rationale had already lost its premise to the colour row above, so the question became moot rather than answered. Reintroducing a homogeneous row register - kernel-side or by a consumer reimplementing one - is amending this record, not filing a refactor: it must re-argue conditions 1 and 3 from the current premises. `ScannableCardTile` and its four-distinguisher contract remain the kernel's surface for hosts presenting scannable cards in their own lane.

## List-face code render concession: DORMANT

The consumer no longer exercises the `CompactCodeView` list-face code render concession: the 26.08.08 rules say "no previews on list cards", and Walt's redesign removed the code render from every list face (walt-ios ios-pjs.5). The concession is not withdrawn - `CompactCodeView` stays, and a host may render an extracted code at list scale again - but its condition 2's "neutral (never issuer-colored) card surface" is replaced by the class tint the colour row grants. Conditions 1 (mechanism-only render, pinned by the `CompactCodeView` construction lock) and 3 (detail-surface provenance unchanged) govern unchanged for any host that takes it up again.

## Document-lane addenda (Android ADR 0005 D1.C / D1.L mirrors)

- **D1.C - the neutral-surface rule for documents is withdrawn.** Documents take a class tint like every other artifact class; the class distinction is carried structurally (type glyph + eyebrow + the words-on-detail trust posture), not by the absence of colour.
- **D1.L - consumers MAY render documents inline in a unified wallet list**, provided the sibling data-model contract holds (documents never masquerade as passes in the model), the row carries no verified affordance, and detail-surface provenance is unchanged. Walt's `WalletStack` is the exercising consumer.

Android sources: `passes-android-main` commits 646bb49 (wpass-80y.3) and 54ec266 (wpass-80y.4).
