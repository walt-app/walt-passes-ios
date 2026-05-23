# passes-ui-3: PassBack tappable links use `AttributedString` + custom URL scheme

Android's `PassBack` uses Compose `ClickableText` with `buildAnnotatedString` plus per-offset click resolution. SwiftUI ships no direct equivalent. The iOS port encodes each detected `LinkSpan` as an `AttributedString` substring with `.link` set to a `x-walt-passes-ui://<index>` URL, then intercepts taps via a scoped `OpenURLAction` so the callback fires with the matching `SecurityIntent` and the URL is never opened externally.

Android source: `passes-android-main/passes-ui/src/main/kotlin/is/walt/passes/ui/PassBack.kt`.
