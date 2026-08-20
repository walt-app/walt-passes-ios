# ADR image-decode-1: In-process bounded image decode-and-retain (ios-dts.2)

Status: accepted (§7 human approval 2026-08-18, recorded on walt-ios `ios-dts.2`).
Mirrors Android `passes-image` / `passes-image-decode` (wpass-gnp, wpass-gyn,
wpass-6yp, wpass-bsf; ADR 0005 addendum I1–I5), reshaped for a platform with no
isolated child process. Sibling of `barcode-decode-1` Deviation 2, which took
in-process bounded decode for barcode READS; this ADR extends that posture to
decoding and RETAINING arbitrary user images as wallet documents.

## The lost containment claim, bluntly

Android decodes every image byte inside a permission-stripped `isolatedProcess`
service: a codec exploit lands in a process with no permissions, no app data, and a
watchdog that kills it at the 5 s budget. iOS has no isolated child process. On this
platform the decode runs **in the app process**. A sufficiently capable ImageIO
exploit therefore lands in Walt itself: app compromise, on-device data theft, and —
once a payment SDK ships — SDK-bounded fraud. No cap below changes that; the caps
change how hard the exploit is to deliver, not where it lands.

## SDK-era pricing

The §7 approval priced this explicitly for the SDK era: the device is assumed
payment-capable soon. Residual risk accepted: a one-shot, PAC-defeating ImageIO
zero-day delivered via a user-imported shared file → app compromise → SDK-bounded
fraud plus on-device data theft. Mitigations that keep the residual one-shot-shaped:
a single passive decode per document (no scripting environment, no attacker-paced
retries), header caps before any allocation, and the render-once retained-display
contract (originals are never re-decoded; display consumes Walt-produced rasters).

## The three-lane design

Only one lane lets attacker bytes reach ImageIO at all:

1. **Camera** — first-party sensor pixels; structurally immune (no attacker bytes).
2. **Gallery** — PHPicker in `.compatible` mode: Photos transcodes HEIC/anything to
   JPEG **out of process** before Walt sees a byte; structurally immune.
3. **Share / file** — the only lane where attacker bytes reach ImageIO, and a
   surface Walt already ships via the barcode read path. This module bounds it.

## Allowlist narrowing: JPEG/PNG only on the retained lane

`ImageDecodeConfig.defaultAllowedContentTypes` admits **JPEG and PNG only** — a §7
term, narrower than both Android's five-container decoder allowlist and iOS's own
`BarcodeDecodeConfig` roster (which stays five-container for the READ lane, per the
same approval):

- **WebP dropped**: the worst still-image CVE history of the roster
  (CVE-2023-4863 class), and not a format iPhone photos arrive in.
- **HEIF/HEIC not admitted natively**: the one lane that would produce HEIC (the
  gallery) transcodes out of process; a shared HEIC simply does not import.
- **JPEG and PNG kept**: the oldest, most-fuzzed parsers in ImageIO; the public
  exploit record concentrates in the exotic codecs, not these two. A single passive
  decode of a JPEG/PNG offers no scripting environment and is one-shot against PAC.

The storage `DocumentFormat` value space keeps `webp` for Android schema-vocabulary
parity; the importer sniff (walt-ios ios-dts.3) is where it is enforced-unreachable.
The insert-side carrier is `DocumentInsert.ImageFormat` (png/jpeg/webp, §7 decision
walt-ios ios-6o2): an image row cannot be constructed with a `pdf` label at all, so
the PDF-only raster-lane guard's trust in the format column is backed by
construction on the write path.

## Caps (mirror of Android `ImageDecodeConfig`, enforced pre-allocation)

25 MB compressed bytes (read bounded, `maxBytes + 1`, never buffering the bomb) ·
12 000 px per side and 50 MP area from the **header**, before any bitmap allocates ·
4 MP output ceiling (a 2048×2048 request sits exactly at it, the Android
`DEFAULT_MAX_IMAGE_DECODE_PX` relationship) · output aspect-fitted and **never
upscaled** · 5 s wall-clock budget. The numbers deliberately match
`BarcodeDecodeConfig`; changing any is a test-breaking edit on both.

## The timeout bounds the wait, not the work

Android's `DecodeWatchdog` kills the sandbox **process** at the budget — a hard
bound on the work. In-process iOS cannot kill anything: `withImageDecodeTimeout`
releases the caller with `.decoderUnavailable` and the orphaned decode runs to
completion on its lane, its result discarded. This is the single biggest
security-property delta of the port, priced in the §7 approval. The header caps are
what keep the actual work bounded; the dedicated lane bank (own serial queues, never
the cooperative pool, refuse-not-queue when full) keeps a wedged decode from
starving anything else — deliberately **separate** from `PassesBarcode`'s banks so
the image-document lane and the camera lane never share capacity.

`ImageDecodeRejectedKind.decoderUnavailable` is retained even though no bind can
fail in-process: it is the timeout bucket, keeps taxonomy parity with Android, and
holds the slot for a future out-of-process decoder behind the same
`BoundedImageDecoder` seam.

**Lane sizing and the concurrent allocation ceiling.** The bank is 4 lanes with NO
overflow-thread tier — a deliberate deviation from the barcode banks' 8+32: the
import surface is single-flight UX, a refusal resolves the caller immediately (it
never waits out the deadline), and the I/O-free preflight (output bound; the
`.data` arm's byte cap) runs OUTSIDE the lanes so a saturated bank cannot mask
those rejection arms. The `.fileURL` read deliberately trades that preflight
visibility for deadline coverage: it runs INSIDE the lane, so a slow source
(file provider, network volume) is bounded by the wait — under a saturated bank
its over-cap rejection surfaces as `decoderUnavailable` rather than
`oversizedAtImport`, an accepted narrowing. The sizing is also the availability price of the containment delta:
each lane can hold a decode allocation up to the ~200 MB the 50 MP header cap
admits, so the worst-case simultaneously-live decode allocation is 4 x ~200 MB ≈
800 MB, and an orphaned (timed-out) decode holds its share until it finishes —
Android reclaims that by killing the sandbox; iOS cannot. More lanes or an overflow
tier would multiply that ceiling.

**Gate ordering is iOS-ahead of Android.** The shared primitive judges the
container BEFORE the header-properties read, so ImageIO's metadata parser (its own
CVE surface) never runs over a container the allowlist rejects. Android's
`OnHeaderDecodedListener` hands MIME and size in one callback and cannot make this
distinction. Both consumers (barcode read lane, retained image lane) get the
stronger ordering.

**The 25 MB bounded read is per-arm.** The `.fileURL` arm reads at most
`maxBytes + 1` and never buffers the bomb; the `.data` arm's bytes are already
resident, so its bound is necessarily the caller's — the ios-dts.3 importer MUST
apply its own bounded read before constructing `.data` (binding note recorded on
that bead).

**The decode is forced eager.** `CGImageSourceCreateImageAtIndex` returns a LAZY
image by default — the codec work would run at first draw, outside any lane or
deadline. The shared primitive passes `kCGImageSourceShouldCacheImmediately` so
the pixel decode happens inside `decodeBounded`, and BOTH consumers therefore run
it under their own bounded wait (the barcode facade moved its whole
ImageIO-then-Vision pipeline inside `withDecodeTimeout` for exactly this reason —
relying on laziness left the codec placement implicit, and forcing it once
escaped the lane entirely).

## The composite importer (ios-dts.3 addendum, §7-approved 2026-08-20)

`PassesDocument` (mirror of Android `passes-document`) orchestrates the
sniff-and-branch import and the composite confirm seam. Two §7 items, both
compositions of previously-approved deviations:

**The C2 delta, bluntly.** On Android, barcode extraction from an imported image
runs inside the isolated barcode worker and only `{payload, format}` crosses the
binder; the host process never runs a codec over the source bytes. iOS has no
isolated worker: the extraction runs in-process, through the SAME bounded
barcode read lane this repo already ships and `barcode-decode-1` Deviation 2
already priced (caps, lanes, five-container read allowlist). The seam shape is
preserved — the importer's internal `BarcodeExtraction` never threads a raw
decode result past it; only the distilled pair and the payload-free
`BarcodeExtractionOutcome` cross.

**Two-decode accounting.** A composite import runs TWO bounded decodes of the
same once-read bytes: the retained-lane decode (display raster/thumbnail,
JPEG/PNG only) and the barcode read-lane decode (extraction, five-container).
That count is Android parity — Android also decodes the same bytes twice, once
per sandbox — so the §7 delta remains only in-process vs sandboxed, priced
above. The composite opt-in keeps the second decode off every plain import:
extraction runs ONLY when the consumer supplies `confirmBarcode`, and the
decoded payload crosses to the app pre-persist only through that hook (and,
post-confirm, `DocumentPersist.barcodedImage`). `webp` is enforced-unreachable
at the importer sniff: recognized, then rejected before any codec contact.

## Structure mapping (Android module ↔ iOS target)

- `passes-image-decode` ↔ `PassesImageDecode`: the mechanism-only header-gated
  decode, generic over the caller's rejection type, no dependencies, sitting below
  the `PassesBarcode` / `PassesImage` peers without adding an edge between them.
  Containment delta: Android folds `IOException` / `IllegalArgumentException` /
  `RuntimeException` and optionally contains `OutOfMemoryError`; ImageIO reports
  failure as nil and Swift has no catchable allocation failure, so the iOS fold
  surface is exactly the nil-returns.
- `passes-image` ↔ `PassesImage`: policy (config, allowlist, taxonomy, facade).
  The binder/service/client/wire plumbing has no iOS analogue and is not mirrored;
  the watchdog maps to the bounded wait above, per-consumer as on Android.
- `ImageSource`'s no-byte-array rule is NOT mirrored: Android forbids a `ByteArray`
  arm because bytes in the caller's heap would defeat its process sandbox; there is
  no sandbox to defeat in-process, and the importer reads its source once into
  bytes before sniffing, so `ImageDecodeSource.data` is the primary arm here. The
  closed two-arm discipline (no path-string arm) is kept.

## Sealed `Document`

`Document` / `DocumentId` are protocols with a closed arm set pinned by
`documentArms` + `DocumentSealedSetTests` (Swift has no sealed protocols).
`ImageDocument` carries `widthPx`/`heightPx` — the bounded raster's dimensions,
never a re-decoded canvas — and deliberately no container format (persistence
detail; display renders a Walt-produced raster). The composite arm rides the
importer step (walt-ios ios-dts.3), as it did on Android (wpass-8lu).
