# passes-ui-2: EAN-13 / UPC-A / Code39 render as a grey placeholder

Apple ships no first-party CoreImage generator for EAN-13, UPC-A, or Code39. `ScannableCardView` surfaces a 1x1 grey CGImage placeholder for these three symbologies so the surface composes; full rendering ships with the implementation bead's follow-up (hand-rolled 1D writer, or a later port of `passes-core`'s `BarcodeEncoder` once it lands on iOS).

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/ScannableCardView.kt`.
