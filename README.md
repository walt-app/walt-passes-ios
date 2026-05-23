# passes-iOS

Walt Passes for iOS — PDF pass parser, encrypted storage, secure rendering.

This is the iOS counterpart of
[`walt-passes-android`](https://github.com/walt-app/passes-android) and is
consumed by [`walt-app/iOS`](https://github.com/walt-app/iOS) as a Swift
Package dependency.

## Status

**Repo standup only.** The targets in this package are protocol scaffolds —
the production implementations (PDF importer, encrypted storage, renderer)
land with the Passes feature epic in `walt-app/iOS` (`ios-382.11`).

## Modules

| Target | Mirrors | Purpose |
|---|---|---|
| `PassesCore` | `passes-core` | Domain types and the `PassParser` trust-claim surface |
| `PassesPDF` | `passes-pdf` | PDF import and bounded rendering |
| `PassesStorage` | `passes-storage` | Encrypted, device-only persistence |

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
