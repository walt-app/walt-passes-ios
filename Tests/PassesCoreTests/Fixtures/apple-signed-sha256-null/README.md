# `apple-signed-sha256-null/` fixture

Real Apple-signed pkpass artifacts from a Tickster event ticket, reduced to the two files
the verifier needs. Used
by `SignatureVerifierTests.realTicksterSignedPkpassIsAppleVerified` to run the full
production verifier path against a wire shape Apple's WWDR-issued signers actually ship.

## Why this fixture matters (`ipass-vjt`)

The `SignerInfo` uses bare `rsaEncryption` for `signatureAlgorithm`, like the Tixly
fixture in `apple-signed/`. What differs is the SHA-256 digest `AlgorithmIdentifier`:
Tickster encodes it as `SEQUENCE { sha256, NULL }` at both `SignedData.digestAlgorithms`
and `SignerInfo.digestAlgorithm`, where Apple PassKit and Tixly leave the parameters
absent. RFC 5754 s2 requires receivers to accept both encodings. swift-certificates 1.19.x
derives an absent-parameters identifier from the signature algorithm and compares with
`==`, so without the SHA-2 arm of the digest-parameter rewrite in
`normalizeCMSSignatureAlgorithm` this genuine pass reads
`.tampered(.manifestSignatureMismatch)`. This fixture is the regression guard for that fix,
and `ticksterFixtureCarriesNullSHA256ParametersAtBothLevels` pins the shape so a renewal
cannot silently swap in a pass that no longer exercises it.

## What's here

- `manifest.json` - file digests only. No PII. `sha256(manifest.json)` equals the signed
  `messageDigest` attribute (`1b536f81...`), proving the content is untampered.
- `signature` - detached PKCS#7 / CMS blob. Embeds the Apple WWDR **G4** intermediate and
  the Tickster leaf (CN `Pass Type ID: pass.com.tickster.common`, O `Tickster AB`, an
  issuer identity, not user data). Chain: leaf -> WWDR G4 (embedded) -> Apple Root CA
  (bundled anchor).

`pass.json` and the image assets are deliberately *not* included: `pass.json` is the only
entry with event / ticket content, and the manifest digest comparison does not need it.

## Android

No Android counterpart. BouncyCastle resolves the digest from the OID alone and never reads
the parameters, so this shape verifies there without a fix and there is no regression to
guard.

## Shelf life

The Tickster leaf's `notAfter` is **2026-12-26T22:03:51 UTC**. As with `apple-signed/`,
iOS verifies under `PermissivePolicy`, which drops the RFC 5280 expiry check, so the
fixture stays `.appleVerified` after the leaf expires as long as the chain still builds to
the bundled Apple Root CA.

## Renewal procedure

Steps 1, 2 and 4 of `apple-signed/README.md` (there is no Android copy to keep in step),
with one extra requirement: the replacement pass must keep the explicit-NULL SHA-2 encoding
at both levels. `openssl asn1parse -inform DER -in
signature` must show `sha256` immediately followed by `NULL` inside the `digestAlgorithms`
SET and again inside the `SignerInfo`; the pinning test fails otherwise.
