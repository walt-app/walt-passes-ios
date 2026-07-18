# barcode-decode-1: Apple Vision (roster-clamped) is the iOS barcode DECODE engine

The Android side decodes barcodes with pure-JVM ZXing inside a zero-permission
`isolatedProcess` (`:barcodeDecoder`), guarded by a watchdog `ProcessKiller`; Walt-side code
"never decodes bytes itself." The iOS kernel had no decode primitive at all — it shipped
**encode only** (`PassesCore/BarcodeMatrix`, `ScannableFormat`, `PassesUI/BarcodeView`; see
`passes-ui-1`). iOS has neither ZXing nor an isolated-UID child process to contain a native codec.

## Decision

`PassesBarcode` decodes with **Apple Vision** (`VNDetectBarcodesRequest`), **clamped by an
allowlist to QR + Code128** — the two symbologies Phase 1 renders and imports. Pre-approved via
`/goal` (2026-06-15). A Swift ZXing/ZXingCpp port was rejected: it would pull the exact native-codec
attack surface Android spends an isolated process containing **into Walt's own address space**,
since iOS offers no isolated child to hold it in. Vision adds no third-party dependency (system
framework), runs the decode **out of process** in system services (the closest iOS analogue to
Android's sandbox), and keeps one Apple-imaging story alongside the CoreImage encode path.

Flip to a Swift ZXing port only if Android symbol parity (EAN-13 / UPC-A / Code39 decode) is later
required — a separate, re-escalatable §7 decision, not a default.

## Deviations from Android (accepted, reviewed)

1. **Different binarizer.** Vision's binarizer is not ZXing's, so fidelity on adversarial/degraded
   inputs differs. The `HostilePayloadFidelity` corpus is **re-baselined** against Vision, not
   assumed to carry over. Result: all corpus payloads (RTL override, zero-width/control chars,
   Cyrillic homoglyph — not NFC/NFKC-normalized, actionable schemes, SQL metacharacters,
   newline/tab, oversize) round-trip **verbatim**; no expectation needed adjusting.
2. **`isolatedProcess` containment claim dropped.** iOS cannot spawn an isolated-UID child, so the
   literal "decode in a killable sandbox process" guarantee does not port. Compensating controls:
   - **Roster clamp** to QR + Code128 (`VNDetectBarcodesRequest.symbologies`), shrinking the parser
     surface to the two formats Phase 1 uses.
   - **Bounded `CGImageSource` decode** — byte-size / per-side-dimension / megapixel caps enforced
     from the image header **before** any bitmap is allocated (decompression-bomb / CVE-2023-4863
     libwebp-class guard).
   - **`Task` timeout** wrapping the decode, the app-level analogue of Android's `ProcessKiller`
     watchdog: it bounds the caller's *wait* (Vision `perform` is synchronous / non-cancellable, so
     a hung decode is orphaned, not killed).
   - **Label-never-autofilled spoof guard**: the decoder returns the payload FAITHFULLY and never
     interprets or acts on it — classification/validation stay downstream in the consumer
     (`QrPayloadKind` / `ScannableCardInputValidator`).
   - Residual protection is Walt-wide: on-device-only data, no network egress from the decode path.
3. **`.data` source arm allowed.** Android forbids a `ByteArray` source because a byte array would
   mean the hostile image had already entered the main-process heap, defeating its isolation. iOS
   drops that containment premise (Deviation 2), so a `.data` arm is acceptable — the app's
   `PHPicker` path naturally yields either in-memory `Data` or a temporary file `URL`.
4. **Live-frame boundary is a `CVPixelBuffer`, not Android's `ByteArray` + Y-plane geometry (K12).**
   Android's `decodeYPlane` takes raw Y-plane bytes plus `rowStride`/`pixelStride`/`reverseHorizontal`
   because ZXing's `PlanarYUVLuminanceSource` consumes exactly that and the shape stays KMP-clean.
   iOS deviates: **Vision ingests a `CVPixelBuffer` natively** (including the camera's biplanar YUV
   formats), so a byte-shaped entry would force the module to *rebuild* a pixel buffer from the bytes
   — touching CoreVideo anyway and discarding Vision's own plane handling. `CVPixelBuffer` is
   **CoreVideo**, not AVFoundation/CoreMedia: the capture glue (`AVCaptureVideoDataOutput` →
   `CMSampleBuffer` → `CMSampleBufferGetImageBuffer`) stays app-side (A8); the kernel receives a bare
   frame snapshot plus a `CGImagePropertyOrientation` (ImageIO), which subsumes Android's
   `reverseHorizontal` mirror flag and also carries rotation. Both paths share ONE Vision core
   (`VisionSymbolDecode`) and ONE roster — the live path does not fork. The live path skips the
   bounded still-image decode (a frame is already-decoded, app-owned pixels, not an untrusted file);
   the roster clamp, faithful-payload posture, and `withDecodeTimeout` wait bound carry over.

## Consequences

Unblocks the app-side decode routing / camera / image-import / share beads, which reuse this roster
clamp and result mapping. The app-side camera privacy string and Share-Extension entitlement remain
separate §7 sign-offs, not resolved here.

Android source: `passes-android-main/passes-barcode/`,
`passes-android-main/passes-barcode-core/src/main/kotlin/is/walt/passes/barcode/BarcodeSymbolDecode.kt`.
Extends the iOS encode surface in `passes-ui-1`.
