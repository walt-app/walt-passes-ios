# passes-ui-2: EAN-13 / UPC-A / Code39 render as a grey placeholder

Apple ships no first-party CoreImage generator for EAN-13, UPC-A, or Code39. `ScannableCardView` surfaces a 1x1 grey CGImage placeholder for these three symbologies so the surface composes; full rendering ships with the implementation bead's follow-up (hand-rolled 1D writer, or a later port of `passes-core`'s `BarcodeEncoder` once it lands on iOS).

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/ScannableCardView.kt`.

## Update 2026-06-03 (ios-cgl.1): create path ships QR + Code128 only

The app-side decision for these three formats is now **defer, not render**. Per ios-cgl.1
(stop-for-decision, user-approved option C — see the ios repo's `decisions-and-learnings.md`
"iOS scannable barcodes ship QR + Code128 only" ADR), the Walt create-a-code picker offers
**only QR and Code128**, so no in-app flow produces an EAN-13 / UPC-A / Code39 card. The grey
placeholder below remains purely as a defensive fallback for an externally-sourced card carrying
one of these symbologies; it is no longer a "follow-up bead will hand-roll a 1D writer" promise.
If the three formats are wanted later, that reopens as a fresh decision (porting a matrix writer
into `BarcodeMatrix` is the no-new-dependency path).

## Update 2026-07-27 (ipass-dq2 / ios-sjf.26): hand-rolled 1D encoders land, placeholder demoted

The fresh decision was taken (human-approved 2026-07-27, recorded on ios-sjf.26: full expansion).
`PassesCore.OneDimensionalBarcodeEncoder` now encodes EAN-13, UPC-A, and Code39 into single-row
`BarcodeMatrix` values from the GS1 / AIM module patterns — no new dependency, the
no-new-dependency path this ADR anticipated. Shape matches what Android's ZXing renders
(Code39 wide:narrow 2:1; UPC-A as the leading-zero EAN-13 symbol; quiet zones included in the
matrix). `BarcodeRenderer` rasterizes the row (nearest-neighbor upscale keeps modules crisp);
`CompactCodeView`'s 1D arm routes through the same encoder. The encoder re-validates structure
(charset / exact length / check digit via `ScannableFormatConstraints`) and returns `nil` on
failure — the grey placeholder survives only as the detail surfaces' render-failure fallback,
and the compact path keeps its white failure tile. Correctness is pinned by structural table
tests plus a Vision decode round-trip per symbology (`OneDimensionalBarcodeEncoderTests`,
`OneDRoundTripTests`). The create picker ships all five formats (consumer bead ios-sjf.26).

## Update 2026-08-17 (ios-pjs.19): one encode entry point, shared with the storage gate

`PassesCore.BarcodeEncoder` is now the single encode entry for the whole roster (since
ios-pjs.15 two roster members — PDF417 and Aztec — are decode-only, and the encoder
refuses them until ios-pjs.16 wires their writer arms): the 1D trio
still encodes through `OneDimensionalBarcodeEncoder`, and the QR / Code128 CoreImage
generator calls moved down from `PassesUI.BarcodeRenderer` into the encoder. Both render
paths (`BarcodeRenderer.cgImage(payload:format:)` and `CompactCodeView.renderImage`) route
through it, and so does the new trial-encode gate on the storage layer's scannable-card
write paths (wpass-1kg analogue) — so save-time approval and draw-time render judge
encodability with the same code and cannot diverge. Failure visuals are unchanged — the 1D
trio degrades to the grey placeholder on detail surfaces; QR / Code128 and the compact path
keep their failure tiles — with one deliberate exception: an empty QR payload now renders
the failure tile instead of the empty-but-scannable symbol `CIQRCodeGenerator` happily
emits (the encoder refuses an empty payload uniformly for every format; a persisted row can
never be empty, so this is reachable only with a caller-constructed in-memory card).

Rows already on disk that clear the validator but fail the encode (the CJK-density case)
are not backfilled: they degrade to the failure tile and stay editable to a valid payload.

## Update 2026-08-17 (ios-pjs.20): QR ships UTF-8 without an ECI header, deliberately

Android pins ZXing's QR CHARACTER_SET to UTF-8 with an ECI header (wpass-qj6) because
ZXing otherwise transliterated non-Latin-1 payloads. The iOS defect shape is inverted:
`CIQRCodeGenerator` always encodes raw UTF-8 bytes and exposes no ECI knob, so the choice
was accept-and-document versus hand-rolling a complete QR encoder (Reed-Solomon, masking,
mode segmentation) just to emit the header. Human decision 2026-08-17: **accept
UTF-8-without-ECI** as the de-facto mobile convention.

Evidence: `QrCharsetRoundTripTests` round-trips Android's original defect payload
("café — naïve — 東京"), CJK-only, and supplementary-plane payloads verbatim through the
production `BarcodeEncoder` -> Vision path — proving the two ends agree on UTF-8. The
ECI-absence claim itself is pinned by `qrByteModeCeilingIsExactAtTheBoundary`: its
2331-byte success arm fails if the generator ever spends capacity on an ECI header
(Vision decodes symbols with and without the header alike, so the round-trip suite
cannot detect one). Residual, accepted risk: a strictly spec-conformant reader
defaults ECI-less symbols to Latin-1 and shows mojibake for non-ASCII payloads (ASCII is
unambiguous everywhere). Capacity consequence: the v40-M byte-mode ceiling stays 2331 on
iOS where Android's ECI header lowers it to 2330 — `qrByteModeCeilingIsExactAtTheBoundary`
pins the number against the live generator so a CoreImage capacity change fails loudly.
