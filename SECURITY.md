# Security Policy

`passes-iOS` is a security-sensitive component of Walt: parsed PDF passes,
their encrypted storage, and rendering go through this package. The
trust-claim surface mirrors `walt-passes-android`.

## Trust-claim surface

Implementations of the public protocols in this package MUST uphold:

- **Untrusted input.** Every byte that arrives at `PassParser` /
  `PDFImporter` is treated as fully untrusted. No MIME or file-extension
  branching may relax validation.
- **Bounded work.** PDF decode, image decode, and parser CPU time are
  bounded; see `docs/PDF_THREAT_MODEL.md` (lands with the Passes feature
  epic).
- **No content in logs.** Telemetry uses enum-only signatures; pass content
  and PII are never logged or sent to a network.
- **Local only.** `PassStorage` writes are encrypted at rest and excluded
  from iCloud backup. There is no remote storage of pass data.
- **Confirmation gating.** Outbound URL / phone / email actions parsed out
  of a pass require explicit user confirmation before launch.

## Reporting a vulnerability

Open a private security advisory via GitHub's "Report a vulnerability"
flow on this repository, or email the project maintainer privately. Please
do **not** file a public issue for security concerns.
