# passes-ui-4: PassImportConfirm has no system-back hook on iOS

Android's `PassImportConfirm` wires `BackHandler` so a system back-press fires `onImportDismissed` telemetry and the dismiss callback. iOS has no equivalent system-back gesture surface at the SwiftUI-view layer; the Cancel button is the sole dismissal path. The trust-contract assertion (dismiss path always fires telemetry) is preserved through the Cancel button alone.

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/PassImportConfirm.kt`.
