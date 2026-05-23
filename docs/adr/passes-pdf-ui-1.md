# passes-pdf-ui-1: SF Symbols `info.circle` replaces the hand-authored info-outline path

Android `passes-pdf-ui` hand-authors the Material "info outline" glyph in `InfoOutlineIcon.kt` to avoid pulling in `material-icons-extended` (a multi-megabyte artifact for a single 24dp path). The iOS port uses Apple's built-in SF Symbols `info.circle` glyph, which is the exact same iconography shipped by the system - no third-party icon dependency and no hand-authored path geometry.

Android source: `passes-android-main/passes-pdf-ui/src/main/kotlin/is/walt/passes/pdf/ui/internal/InfoOutlineIcon.kt`.
