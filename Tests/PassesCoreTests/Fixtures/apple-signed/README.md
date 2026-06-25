# `apple-signed/` fixture

Real Apple-signed pkpass artifacts pulled from a Tixly Chroniques ticket, copied
verbatim from the Android side
(`passes-android/passes-core/.../fixtures/apple-signed/`). Used by
`SignatureVerifierTests.realAppleSignedPkpassIsAppleVerified` to exercise the full
production verifier path against a wire shape Apple actually ships, on top of the
bundled Apple Root CA anchor set.

## Why this fixture matters (walt-passes-ios#31)

The `SignerInfo` here uses the bare `rsaEncryption` OID (`1.2.840.113549.1.1.1`,
parameters absent) for `signatureAlgorithm`, conveying the hash separately in
`digestAlgorithm` (`sha256`). swift-certificates 1.19.x does not recognize the bare
OID, so without the `normalizeCMSSignatureAlgorithm` pre-pass the production verifier
misclassifies this valid pass as `.tampered(.manifestSignatureMismatch)`. This fixture
is the regression guard for that fix.

## What's here

- `manifest.json` — file digests. No PII; the digest values reveal nothing about ticket
  contents. `sha256(manifest.json)` equals the signed `messageDigest` attribute, proving
  the content is untampered.
- `signature` — detached PKCS#7 / CMS blob. Embeds the Apple WWDR **G4** intermediate and
  the Tixly leaf certificate (CN `Pass Type ID: pass.com.tixly` — an issuer identity, not
  user data). Chain: leaf → WWDR G4 (embedded) → Apple Root CA (bundled anchor).

`pass.json` and the localized `*.lproj/pass.strings` files are deliberately *not*
included: they are the only entries with passenger / event / ticket-number content, and
the manifest digest comparison does not require them.

## Shelf life

The Tixly leaf certificate's `notAfter` is **2027-02-04T10:18:41 UTC**. Unlike Android
(which sets the PKIX path-build date to *now* and so downgrades to `CertChainIncomplete`
on expiry), iOS verifies under `PermissivePolicy`, which drops the RFC 5280 expiry check.
So this fixture stays `.appleVerified` after the leaf expires, as long as the chain still
builds to the bundled Apple Root CA. The fixture only breaks if that anchor is unbundled
or the embedded chain structure changes.

## Renewal procedure

1. Obtain any current Apple-signed pkpass (any vendor; Apple Wallet sample passes work).
2. Unzip it and copy `manifest.json` and `signature` into this directory, replacing the
   files here. Do **not** copy `pass.json`, `*.lproj/`, or image assets — they are
   PII-bearing and unnecessary for the verifier path.
3. Keep Android and iOS copies byte-identical (`shasum -a 256` parity).
4. Rerun `swift test --filter SignatureVerifierTests` to confirm green.
