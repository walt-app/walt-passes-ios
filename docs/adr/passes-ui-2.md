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

`PassesCore.BarcodeEncoder` is now the single encode entry for the whole roster: the 1D trio
still encodes through `OneDimensionalBarcodeEncoder`, and the QR / Code128 CoreImage
generator calls moved down from `PassesUI.BarcodeRenderer` into the encoder. Both render
paths (`BarcodeRenderer.cgImage(payload:format:)` and `CompactCodeView.renderImage`) route
through it, and so does the new trial-encode gate on the storage layer's scannable-card
write paths (wpass-1kg analogue) — so save-time approval and draw-time render judge
encodability with the same code and cannot diverge. Failure visuals are unchanged: the 1D
trio degrades to the grey placeholder on detail surfaces; QR / Code128 and the compact path
keep their failure tiles.
