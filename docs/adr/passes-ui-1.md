# passes-ui-1: CoreImage native filters replace ZXing for barcode rendering

The Android `BarcodeView` and `ScannableCardView` use ZXing (`MultiFormatWriter` + `BitMatrix`) on JVM to encode QR / PDF417 / Aztec / Code128 / EAN-13 / UPC-A / Code39. The iOS port uses Apple-native CoreImage generators (`CIQRCodeGenerator`, `CIPDF417BarcodeGenerator`, `CIAztecCodeGenerator`, `CICode128BarcodeGenerator`) so `walt-passes-ios` does not pick up a third-party encoder dependency.

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/BarcodeView.kt`, `ScannableCardView.kt`.
