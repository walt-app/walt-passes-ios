# Wire-order `signedAttrs` and the CMS algorithm pre-pass

Background for `SignatureVerifier.swift`, `WireOrderSignedAttrs.swift` and
`CMSSignatureAlgorithmNormalizer.swift`. Beads: `ipass-10g`, `ipass-c8p`.
Android counterparts: `wpass-x70` (824abc5), GH `walt-app/walt-passes-android#176`.

## The bug

RFC 5652 says a CMS signature covers the DER encoding of `SignedAttributes`, and DER
requires a SET's elements sorted by their encodings. Some issuers' tooling signs the
elements in the order it emitted them instead. Observed on Android: `contentType`,
`messageDigest`, `signingTime`, whose encodings `0x18` / `0x23` / `0x1c` are not
ascending.

iOS hits this through a different arm than Android did. swift-asn1's `DER.lazySet`
throws `"SET OF fields are not lexicographically ordered"`, and `CMSSignerInfo`
deliberately routes `signedAttrs` through `DER.set`, so the blob fails at **parse** and
swift-certificates supplies nothing. BouncyCastle instead parsed the set and only then
re-encoded it sorted before hashing. Hence iOS reported
`Tampered(SignatureCryptoFailure)` where Android reported
`Tampered(ManifestSignatureMismatch)`: the same rejection of a sound pass, a different
arm.

Apple Wallet, Google Wallet, FossWallet and OpenSSL all verify over the bytes as
received and accept these passes.

## Why the fallback is shaped the way it is

swift-certificates parses `SignerInfo.signedAttrs` as OPTIONAL, and when it is absent
`CMS.isValidSignature` verifies the signature directly over the `dataBytes` it is
handed. So the fallback strips `[0] signedAttrs` from the blob and passes the attribute
bytes, exactly as received, as `dataBytes`. The library still locates the signer
certificate, enforces its own
`digestAlgorithmFor(signatureAlgorithm) == digestAlgorithm` cross-check, verifies the
signature under the leaf's public key, and builds the chain through the same `Verifier`
and `PermissivePolicy` as the strict path. No second copy of the
`appleVerified` / `selfSigned` / `certChainIncomplete` mapping exists.

This was a user-approved §7 decision (2026-08-04, recorded on `ipass-10g`), chosen over
a full hand-parse that would also have re-implemented the leaf selection and the chain
classification.

Ruled out during investigation, with the reasons, so they are not revisited:

- **Reusing the library's parsed structures.** `CMSContentInfo` / `CMSSignedData` /
  `CMSSignerInfo` are `internal`, not `@_spi(CMS) public`. Unreachable.
- **Letting the library classify the chain on the unmodified blob.**
  `CMS.isValidSignature` checks the signature before the chain, so a blob whose
  signature it rejects never reaches chain validation.
- **Sorting `signedAttrs` into DER order and re-verifying.** The signature is over the
  unsorted bytes, so this reproduces the failure.

## Why the fallback's own digest comparison is load-bearing

Stripping `signedAttrs` also strips the one signed attribute the library validates: it
compares `messageDigest` against the digest of the content, and it never looks at
`contentType`. Without re-doing that comparison a tampered `manifest.json` would keep a
perfectly valid signature over its untouched attributes and verify. Mutation-tested:
removing the comparison makes a tampered manifest pass.

Both halves of the binding are read from one parse, so the digest checked is lifted out
of the very bytes verified.

## Fail-closed floor

The fallback returns nil - leaving the strict path's verdict standing, never relabelling
it - for anything but a definite-length DER blob carrying a single SignerInfo with a
present `[0] signedAttrs` holding exactly one single-valued `messageDigest` whose digest
matches. Indefinite-length BER lands here too, since `DER.parse` rejects it, so the
fallback is deliberately narrower than the strict path it recovers from.

The single-signer guard is **load-bearing, not defense-in-depth**: `reserialized` emits
exactly one SignerInfo, so the library never sees extra signers and its own
`"Too many signatures"` check cannot catch them. Mutation-tested.

## The algorithm pre-pass

`normalizeCMSSignatureAlgorithm` fixes two encodings swift-certificates 1.19.x rejects,
both targeted structurally at the sole SignerInfo so certificates are never touched:

1. **Bare `rsaEncryption` `signatureAlgorithm`** -> the implied
   `shaNNNWithRSAEncryption`. Apple PassKit ships the bare OID.
2. **SHA-1 `digestAlgorithm` with absent parameters** -> explicit NULL.
   `AlgorithmIdentifier(digestAlgorithmFor:)` maps `.sha1WithRSAEncryption` to `.sha1`,
   which carries NULL, while every other digest maps to a `…UsingNil` (absent-parameters)
   variant. The comparison is `==` on a synthesized `Hashable`, so parameters must match
   exactly.

On (2): both real SHA-1 pkpasses inspected encode `SEQUENCE { sha1, NULL }` at both the
SignedData and SignerInfo levels, which is the shape the library already accepts, so this
is a legal-encoding gap rather than an observed failure. Apple encodes SHA-256 with
parameters absent, which is why the asymmetry only bites SHA-1.

Android is no guide to whether the gap matters, because it cannot exhibit it. BouncyCastle's
`DefaultCMSSignatureAlgorithmNameGenerator.getSignatureName` resolves the algorithm from the
two OIDs alone and never reads `getParameters()` (verified by `javap` against bcpkix-jdk18on
1.84), so both encodings work there. An absent-parameters SHA-1 pass would therefore have
verified on Android and read `Tampered` on iOS - a parity divergence, not merely a
theoretical one, which is why the rewrite is worth carrying despite no observed pass needing
it.

Two levels carry a `digestAlgorithm`: the SignerInfo, and the SignedData-level
`digestAlgorithms` SET. The library checks them separately - `expectedDigestAlgorithm ==
signer.digestAlgorithm` for the first, `digestAlgorithms.contains(signer.digestAlgorithm)`
for the second - so both must end up carrying NULL. Nothing requires an issuer to use the
same encoding at both levels, and all four combinations are legal, so the two are evaluated
independently and whichever side omits the parameters is rewritten. Fixing one level alone
just trades one false `Tampered` for another.

No rewrite is attempted unless the SET is a single SHA-1 identifier that can be kept in
step: the library parses it with `DER.set`, which requires lexicographic order, so
re-encoding one member of a larger set risks breaking the ordering, and a larger set cannot
be guaranteed to hold the rewritten identifier the `contains` check looks for.

Neither field is covered by the signature, so no rewrite can make a tampered pass verify.
