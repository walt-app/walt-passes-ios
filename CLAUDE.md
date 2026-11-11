# Walt Passes (iOS)

Walt Passes kernel: PDF/pkpass parsing, device-only encrypted storage, and secure rendering, consumed by `walt-app/ios` as an SPM dependency. Mirrors `walt-passes-android`. See `README.md` for the target map and `SECURITY.md` for the trust-claim surface every implementation must uphold.

## Build & Test

```bash
swift build
swift test          # Linux builds only non-Apple-framework targets; full suite runs via xcodebuild on an iOS simulator
```

## Beads

Use `bd` for task tracking. The bead database is local-only: `.beads/issues.jsonl` is gitignored and never committed. Keep bead text out of commits, PRs and GitHub issues.
