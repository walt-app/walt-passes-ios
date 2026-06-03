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
