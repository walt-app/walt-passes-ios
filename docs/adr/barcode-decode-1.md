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

## Update 2026-07-27 (ipass-dq2 / ios-sjf.26): roster expanded to Android symbol parity

The "Flip … only if Android symbol parity is later required" clause fired: the re-escalatable §7
decision was taken (human-approved 2026-07-27, recorded on ios-sjf.26 — full expansion). The
answer is NOT a ZXing port — decode stays on Vision; `RosterSymbology.requested` grows to
`[.qr, .code128, .ean13, .code39]`, still an allowlist and still the only place the roster is
defined. UPC-A has no `VNBarcodeSymbology`: Vision reports it as EAN-13 with a leading zero, and
`RosterSymbology.fold` maps that back to `.upcA` with the 12-digit payload — the same
classification ZXing produces on Android, so cross-platform scans of one physical card agree.
Every compensating control from the original decision (bounded still-image decode, decode
timeout, faithful-payload posture, label-never-autofilled) carries over unchanged; the roster
clamp now matches Android's `POSSIBLE_FORMATS` pin exactly. Encode-side parity lands in the same
change (`passes-ui-2`, revised).

## Update 2026-08-04 (ipass-f8p): the decode timeout runs on lanes this module owns

The `Task` timeout above did not hold the property it claimed. It scheduled the decode with
`Task.detached`, which runs on the shared Swift **cooperative pool** — a fixed-width pool that
does not grow — while the deadline was a `Task.sleep` **timer** that fires on wall-clock time
regardless. The two racers were not on equal footing: a caller that parks the pool's threads (the
in-repo example is `SignatureVerifier.runBlocking`'s `semaphore.wait()`, whose own comment names
this hazard) could keep the decode from ever *starting*, while the deadline fired on schedule and
won by default.

The guard therefore reported a timeout for decodes that had not run. It measured thread
availability, not decode duration. `full-ci` surfaced it unambiguously: a test whose entire
operation is `{ "REAL" }` — microseconds of CPU — lost a **5 second** race. Reproduced locally at
100% under a parked pool.

**Change (human-approved §7, 2026-08-04, recorded on ipass-f8p).** `withDecodeTimeout` submits the
decode to a bank of dedicated serial `DispatchQueue`s that `PassesBarcode` owns, and schedules the
deadline on a separate owned lane. Measured with the pool parked: work submitted via
`Task.detached`, a *concurrent* `DispatchQueue`, or `DispatchQueue.global` had not begun after 20s;
a dedicated serial queue began in 0.1ms. Concurrent and global queues draw from the same thread
pool the cooperative pool exhausts, so only dedicated lanes are immune — this is why the bank is
serial queues rather than one concurrent queue. A bank rather than a single lane because the
still-image and live-frame paths decode concurrently, and one lane would trade starvation-by-pool
for starvation-by-queue (measured: 12 concurrent 0.3s decodes took 3.6s of a 5s budget on one
lane, 0.6s across a bank). Lane width is sized to in-flight decodes rather than to cores, since
Vision decodes out of process and a lane waits on that service rather than burning one: tying the
width to `activeProcessorCount` left ~41 concurrent decodes queued ~14 deep on a 3-core runner and
blew the budget by queueing alone.

**A decode never waits behind another decode**, so only its own duration can exhaust its budget.
A free lane is reused; when every lane is occupied the work spills to a transient thread rather
than queueing. This is not a refinement — a bounded bank alone reproduces the defect at a higher
threshold, and it did: with 16 lanes the gate still failed roughly one run in three, an instant
operation reporting `decodeTimedOut` against a 5s budget purely because it queued. Occupied lanes
are the normal case, not a corner: a timed-out decode is orphaned but keeps running, since Vision
`perform` is non-cancellable.

**Spilling is capped at 64 threads**, and an earlier draft of this entry was wrong to claim the
thread count was "bounded by concurrent demand, which the app controls" and therefore not
attacker-reachable. It is reachable. Because orphaned decodes never release, in-flight count is
cumulative rather than concurrent: an image crafted to wedge Vision — untrusted input, and exactly
the slow-loris case this guard exists for — re-fed by the per-frame scan loop, mints a permanent
thread per frame. Past the ceiling decodes queue again, which reintroduces false timeouts in that
pathological tail. `LanePlacementTests.spillsOnlyUntilTheCeiling` pins the ceiling, and
`theBankCannotOutgrowItsDocumentedThreadCeiling` pins the total: **at most 80 live decode threads**,
16 lanes plus the 64-thread spill.

Be precise about what that tail costs, because an earlier draft of this paragraph was wrong a second
time: it called the queueing tail "a degraded decode" against "a crash" for unbounded threads. Both
ends are a crash. The queue past the ceiling has no depth cap, and each queued submission retains its
payload — a `CGImage` up to the ~50MP `BoundedImageDecode` limit, or a camera `CVPixelBuffer` — behind
a lane head that a wedged decode never releases. So the trade is bounded threads for unbounded
retention, and the far end is jetsam rather than thread exhaustion. It is still the better end of the
trade (a thread costs its stack *plus* whatever it retains), and it is **not a regression**: before
this change the same closures queued unboundedly on the cooperative pool and retained the same
buffers. Capping the queue and refusing past it is ipass-ba3, done in the 2026-08-06 update below.

The bank is process-global and shared by the still-image and live-frame decoders, and an orphaned
decode never returns its slot, so occupancy is cumulative for the life of the process. Enough wedging
inputs through the still-image path can therefore starve the live-frame path permanently. Isolating
the two banks is ipass-9tv, done in the 2026-08-06 update below.

Lanes track decode **depth**, not a busy flag. Once the ceiling queues a second decode onto a lane,
a flag under-reports: the first decode clears it on completion while the queued one is still running
there, so the lane reads free and the next submit queues behind untracked work. That false timeout
outlives the pressure that caused it — measured 16/16 decodes timing out with idle lanes available,
against 0/16 once lanes count depth.

Placement is a value type (`LanePlacement`) rather than state tangled into the queues, so these
invariants are pinned deterministically at two lanes and a ceiling of one, in
`LanePlacementTests`. The measurements above came from integration tests that saturated the real
bank with 80 live holders; that is how the leak was found, but as a permanent gate it was both
slow and unreliable — on a 3-core runner "80 holders must start" is an assertion about the runner,
and it failed there on correct code. One end-to-end check
(`decodeDoesNotQueueBehindSaturatedLanes`) remains for the wiring.

What does NOT change: the timeout still bounds only the caller's *wait*; Vision `perform` remains
synchronous and non-cancellable, so a hung decode is still orphaned rather than killed, and its
result is still discarded. The roster clamp, bounded still-image decode, faithful-payload posture,
and label-never-autofilled guard are untouched.

**`DecodeFailureReason.decodeTimedOut` added**, splitting the timeout out of `decoderUnavailable`.
The two called for opposite responses while sharing one value: an unavailable decoder will not
succeed on retry, a timed-out one is a load signal and the same input may decode fine later.
Conflating them also cost a real misdiagnosis — a run of timeouts was read as an absent Vision
framework (ipass-42i) — because no value could distinguish the two. Public enum change on
`BarcodeDecodeResult`; `decoderUnavailable` keeps its original meaning, a Vision `perform` failure.

Honest residual: this fixes which *executor* the decode runs on, not the fact that resuming the
caller still needs the caller's own executor. If the caller's pool is blocked, it observes the
result late — the guard bounds the wait it controls, and cannot bound delivery into a blocked
caller. `DecodeTimeoutTests.decodeNeverRunsOnTheCooperativePool` pins that the decode runs on a
context this module owns — a lane, or a named overflow thread, never the cooperative pool — and
`expiredBudgetReportsDecodeTimedOut` on each decoder pins the reported arm.

## Update 2026-08-06 (ipass-ba3, ipass-9tv): the bank refuses instead of queueing, and there are two

The entry above closed with two holes it had named but not fixed. Both are fixed here.

**A full bank now refuses (ipass-ba3).** `LanePlacement.claim` returns a third target, `.refused`,
once every lane and the whole overflow ceiling are taken. `submit` drops the work, which releases the
payload the closure captured. Total in-flight work per bank is therefore capped at
`decodeLaneCount + decodeMaxOverflowThreads` — the accounting no longer has an unbounded arm.

Be precise about what "retains nothing" means here, because the obvious reading is too strong. The
*bank* retains nothing: what was unbounded was the queue, and the queue is gone. The refused
**caller** still holds its own payload, because `withDecodeTimeout` is suspended and its `operation`
parameter stays alive in the async frame until the deadline resolves it. So retention past the cap is
bounded by the budget (5s) times the number of concurrent callers, and concurrent callers are bounded
by the app: the scan loop gates itself to one decode in flight, and imports are user-driven one at a
time. Bounded and small, rather than zero.

A refusal is **not** resolved early on purpose. The caller waits its full budget and is then told
`decodeTimedOut` by the deadline that was already scheduled. Resolving instantly was considered and
rejected: `FrameScanLoop` clears its in-flight gate on each result, so instant refusals would spin it
at camera rate against a bank that cannot recover, burning battery to no end. The wait is the
backpressure.

Honest about what refusal does not fix: a saturated bank never drains, because orphaned decodes never
return their slots. Every decode after saturation is refused for the life of the process, and the arm
the caller sees — `decodeTimedOut`, whose contract says the same input may decode fine later — is
misleading in exactly that state. Reporting saturation distinctly was weighed and declined
(2026-08-06): it is a public enum change plus consumer copy, for a state reachable only by ~80
deliberately wedging decodes, and it would add a second iOS-only arm on top of the divergence recorded
below. Revisit if saturation is ever observed in the wild.

**The two decode paths no longer share a bank (ipass-9tv).** `withDecodeTimeout` takes a `DecodeBank`
— `.stillImage` for untrusted files off the share sheet or picker, `.liveFrame` for app-captured
camera frames — and each bank is its own `DecodeLanes` instance with its own lanes, its own overflow
ceiling, and its own placement accounting. Wedging the still-image path can no longer consume a slot
the scanner needs, which was the whole failure: since occupancy is cumulative, ~80 wedging imports
used to pin the shared bank and leave the camera returning `decodeTimedOut` until the app was
force-quit.

Sizing: **8 lanes plus a 32-thread spill per bank**, halved from 16 + 64 so that two banks still total
the documented **80 live decode threads**. `theBankCannotOutgrowItsDocumentedThreadCeiling` now asserts
the product across `DecodeBank.allCases`, so adding a third bank cannot quietly triple the ceiling.
Halving each bank is affordable because real concurrent demand per path is one or two decodes, not
eight; the ADR's original width argument was about not queueing under a burst, and 8 lanes clears that
with room. Idle queues create no threads, so the second bank costs nothing until it is used.

The cost of isolation, stated plainly: the live-frame path can now be starved by ~40 wedged decodes
instead of ~80, because it no longer has the other path's capacity to fall back on. That is the right
trade — the fallback ran in the wrong direction, letting untrusted input eat the trusted path's
slots — but it is a real halving, not a free win.

**Lane occupancy is a flag again, not a depth count.** The count existed because claims queued onto
occupied lanes; a flag under-reported once a second decode was queued behind a running one (measured
16/16 false timeouts, above). Nothing queues now, so a lane is binary, and a count that can only be 0
or 1 is dead generality. The regression the count guarded against returns the moment queueing does,
so `LanePlacementTests.refusesRatherThanQueueingOntoAnOccupiedLane` pins the property the flag depends
on: a full bank refuses rather than handing back a lane that is already running something.

Full-saturation isolation is **not** pinned by an integration test, for the reason the entry above
already gives: "40 holders must start" is an assertion about the runner, and that shape of test failed
on correct code. It is pinned by construction (two instances, separate accounting) plus the cheap
cross-bank probe in `decodeDoesNotQueueBehindSaturatedLanes`, which saturates the still-image lanes
and asserts a live-frame decode still returns instantly.

That surviving integration check needed a fix here, and the reason is worth recording because it is
the same hazard in a new place. It waited for `decodeLaneCount + 1` hogs before probing, on the
argument that waiting for all of them "would assert how fast the runner mints threads". Halving the
lane count halved that precondition too, so the probe now ran while the runner was still minting the
remaining spill threads, and had to win a 500ms budget against that storm — green locally, red on the
3-core CI runner, on correct code. Both forms assert runner speed; they differ in how much slack they
allow. Waiting for every hog spends the generous 20s allowance and leaves the bank settled, so the
probe measures placement rather than thread-start latency.

## Update 2026-08-06 (ipass-7vo): the failure taxonomies diverge from Android on purpose

`DecodeFailureReason.decodeTimedOut` has no Android counterpart and **will not get one**. Android is
not merely missing the arm — it cannot populate it. `DecodeWatchdog` runs *inside* the isolated decode
process and expires by calling `killer.killSelf()`; the main process only ever observes the dropped
binder. `BarcodeDecodeClient` folds that `RemoteException` together with a failed bind, a `false`
`transact`, and any malformed reply into `DecoderUnavailable`, and nothing on that side can tell a
watchdog kill from a decoder that was never there. Adding the arm would mean adding a second,
client-side timer duplicating the watchdog, plus a wire code in `DecodeFailureReasonWire` and its
fail-closed surface test, plus consumer copy — to carry a value the platform cannot distinguish.

iOS has the opposite constraint: Vision `perform` cannot be killed, so a timeout genuinely leaves the
decoder present and working, and conflating it with "the decoder is gone" already cost a misdiagnosis
(ipass-42i). The two platforms are reporting what they can actually observe.

So the mirror claim is scoped rather than upheld: the two kernels mirror each other's *contracts* —
same result shape, same roster clamp, same faithful-payload posture — and their failure taxonomies may
diverge where the process models do. `README.md` says so. This is the rule for the next divergence
too, which is why the saturation arm weighed above was declined rather than debated again.
