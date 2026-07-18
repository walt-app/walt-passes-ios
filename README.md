# passes-iOS

Walt Passes for iOS — PDF pass parser, encrypted storage, secure rendering.

This is the iOS counterpart of
[`walt-passes-android`](https://github.com/walt-app/passes-android) and is
consumed by [`walt-app/iOS`](https://github.com/walt-app/iOS) as a Swift
Package dependency.

## Modules

Pure-logic targets are split from their SwiftUI counterparts (`*Core` vs. the
UI target) so the logic stays testable without a UI host.

| Target | Purpose |
|---|---|
| `PassesCore` | Domain types, the `PassParser` trust-claim surface, and pkpass signature verification (swift-certificates) |
| `PassesPDFCore` | Pure PDF parsing and validation |
| `PassesPDF` | PDF import and bounded rendering |
| `PassesPDFUI` | SwiftUI document views |
| `PassesStorage` | GRDB-backed, device-only encrypted persistence (iOS Data Protection) |
| `PassesUICore` | UI identity primitives and pass-display logic |
| `PassesUI` | SwiftUI pass / scannable-card views |

## Security

See [`SECURITY.md`](SECURITY.md) for the trust-claim surface every
implementation must uphold and how to report a vulnerability.

## Build & test

```bash
swift build
swift test
```

iOS-specific code paths build via `xcodebuild` against an iOS simulator.

## License

MIT, see [`LICENSE`](LICENSE).
