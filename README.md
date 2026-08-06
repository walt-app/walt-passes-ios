# passes-iOS

Walt Passes for iOS — PDF pass parser, encrypted storage, secure rendering.

This is the iOS counterpart of
[`walt-passes-android`](https://github.com/walt-app/passes-android) and is
consumed by [`walt-app/iOS`](https://github.com/walt-app/iOS) as a Swift
Package dependency.

The two kernels mirror each other's *contracts* — the same result shapes, the
same trust-claim surface, the same faithful-payload posture. They are allowed to
diverge where the platforms' process models genuinely differ, and where they do,
the ADR for that area records why. `DecodeFailureReason.decodeTimedOut` is the
current example: Android kills its isolated decode process and cannot observe a
timeout separately from an absent decoder, while iOS cannot kill Vision
mid-decode and must distinguish the two (see
[`docs/adr/barcode-decode-1.md`](docs/adr/barcode-decode-1.md)).

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
