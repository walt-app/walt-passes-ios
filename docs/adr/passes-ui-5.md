# passes-ui-5: `UiTelemetryGuard.onImportRejected` and `PassImportRejectionSheet` deferred

`ParseFailureKind` is not yet ported in `PassesCore` (an explicit `TODO` in `passes-core` `ParseResult.swift` points at the flattening helpers that would land it). `UiTelemetryGuard` therefore omits `onImportRejected(kind:)`, and `PassImportRejectionSheet` is deferred entirely. Both ship with the bead that ports `ParseFailureKind` / `ParseFailureReason` into `PassesCore`.

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/PassImportRejection.kt`.
