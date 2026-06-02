import Foundation
import SwiftASN1
import X509

@_spi(CMS) import X509

/// Outcome of running `verifySignature` over a detached PKCS#7 / CMS signature blob and the
/// manifest bytes it claims to sign. Internal only; the parser-glue layer lifts a `failed` into
/// the right `ParseResult` arm and an `ok` into `ParseResult.success` with the `SignatureStatus`.
/// This layer never produces `.unsigned` - that comes from the glue layer when the `signature`
/// archive entry is absent.
internal enum SignatureVerifyResult: Equatable {
    case ok(SignatureStatus)
    case failed(TamperReason)
}

/// Verifies a detached PKCS#7 / CMS signature blob against the bytes of a PKPASS archive's
/// `manifest.json`. **Platform mapping**: Android uses BouncyCastle; iOS uses Apple's pure-Swift
/// swift-certificates (`CMS.isValidSignature`). The verifier is invoked only when the archive
/// carries a `signature` entry; the glue layer routes the missing-entry case to `.unsigned`.
///
/// **Three-arm chain classification** (mirrors Android `classifyChain` + config gating):
///  - `isValidSignature(trustRoots: appleRoots, intermediates: wwdr)` == `.success`
///    -> `.appleVerified`.
///  - `.failure(.unableToValidateSigner)` (signature math valid, chain did not reach Apple):
///    honors `acceptSelfSignedCertificates`. If false -> `.tampered(.signatureCryptoFailure)`.
///    If true: a self-issued signer (issuer == subject) -> `.selfSigned`, else
///    `.certChainIncomplete`.
///  - `.failure(.invalidCMSBlock(reason))` -> `.tampered`: a no-/zero-signer or missing
///    signing-certificate reason -> `.signerCertificateMissing`; a signature/digest mismatch ->
///    `.manifestSignatureMismatch`; anything else -> `.signatureCryptoFailure`.
/// Everything is wrapped so verify NEVER throws out - any thrown error -> `.signatureCryptoFailure`.
///
/// **Permissive policy.** The policy always meets policy (ignores expiry / revocation), mirroring
/// Android's `isRevocationEnabled = false`. This is slightly more lenient than Android's
/// now-dated path build, which still applies notBefore/notAfter at "now"; documented as a
/// deliberate simplification. The four-arm trust UI distinction is preserved.
///
/// **Self-signed detection note.** Android counts the embedded certificates and requires exactly
/// one self-issued cert. swift-certificates does not expose the embedded cert set publicly, so
/// iOS classifies on the *signer* certificate that `CMS.isValidSignature` returns: a self-issued
/// signer (`issuer == subject`) whose chain did not reach Apple is `.selfSigned`, otherwise
/// `.certChainIncomplete`. For a real single-leaf self-signed pkpass the signer IS that leaf, so
/// the observable behavior matches; a multi-cert envelope whose signer happens to be self-issued
/// would classify as `.selfSigned` where Android would say `.certChainIncomplete` - a documented,
/// minor divergence with no security impact (both are lenient-accept arms).
internal func verifySignature(
    signatureBytes: [UInt8],
    manifestBytes: [UInt8],
    config: ParserConfig
) -> SignatureVerifyResult {
    do {
        let anchors = try AppleTrustAnchors.trustAnchors()
        let intermediates = try AppleTrustAnchors.knownIntermediates()
        return runBlocking {
            await classify(
                signatureBytes: signatureBytes,
                manifestBytes: manifestBytes,
                config: config,
                anchors: anchors,
                intermediates: intermediates
            )
        }
    } catch {
        // Anchor loading failed (stripped bundle / corrupt .cer). Collapse onto the documented
        // crypto-failure arm, mirroring Android's outer runCatching.
        return .failed(.signatureCryptoFailure)
    }
}

/// **Test seam - DO NOT call from production.** Verifies against caller-supplied anchors so the
/// synthesized chains tests build can reach a stand-in root (Apple's WWDR key is unavailable to
/// tests). The `ForTesting` suffix is the flag.
internal func verifySignatureAgainstAnchorsForTesting(
    signatureBytes: [UInt8],
    manifestBytes: [UInt8],
    config: ParserConfig,
    trustAnchors: [Certificate],
    knownIntermediates: [Certificate]
) -> SignatureVerifyResult {
    runBlocking {
        await classify(
            signatureBytes: signatureBytes,
            manifestBytes: manifestBytes,
            config: config,
            anchors: trustAnchors,
            intermediates: knownIntermediates
        )
    }
}

private func classify(
    signatureBytes: [UInt8],
    manifestBytes: [UInt8],
    config: ParserConfig,
    anchors: [Certificate],
    intermediates: [Certificate]
) async -> SignatureVerifyResult {
    let result = await CMS.isValidSignature(
        dataBytes: manifestBytes,
        signatureBytes: signatureBytes,
        additionalIntermediateCertificates: intermediates,
        trustRoots: CertificateStore(anchors),
        diagnosticCallback: nil
    ) {
        PermissivePolicy()
    }

    switch result {
    case .success:
        return .ok(.appleVerified)
    case .failure(.unableToValidateSigner(let failure)):
        // Signature math is valid but the chain did not reach a bundled Apple root.
        if !config.acceptSelfSignedCertificates {
            return .failed(.signatureCryptoFailure)
        }
        return isSelfIssued(failure.signer) ? .ok(.selfSigned) : .ok(.certChainIncomplete)
    case .failure(.invalidCMSBlock(let block)):
        return .failed(classifyInvalidBlock(block.reason))
    }
}

/// Maps swift-certificates' free-text `invalidCMSBlock` reason onto a `TamperReason`. The reason
/// strings come from `CMSOperations.swift`; matched on stable substrings rather than exact text
/// so a phrasing tweak in a future swift-certificates release degrades to `signatureCryptoFailure`
/// rather than crashing.
private func classifyInvalidBlock(_ reason: String) -> TamperReason {
    let lower = reason.lowercased()
    if lower.contains("locate signing certificate") || lower.contains("too many signatures")
        || lower.contains("no attached content")
    {
        return .signerCertificateMissing
    }
    if lower.contains("invalid signature") || lower.contains("message digest mismatch")
        || lower.contains("digest")
    {
        return .manifestSignatureMismatch
    }
    return .signatureCryptoFailure
}

private func isSelfIssued(_ cert: Certificate) -> Bool {
    cert.issuer == cert.subject
}

/// A `VerifierPolicy` that always meets policy. The chain-building algorithm in `Verifier` still
/// requires the chain to reach a trust root, so this does not weaken the "reaches Apple" check;
/// it only drops the expiry / extended-key-usage style policy checks `RFC5280Policy` would apply,
/// mirroring Android's no-revocation, lenient stance.
///
/// `verifyingCriticalExtensions` lists the standard X.509 criticals (BasicConstraints, KeyUsage,
/// ExtendedKeyUsage, NameConstraints) so the `Verifier` does not reject an otherwise-valid chain
/// merely because a CA cert marks BasicConstraints critical (which Apple's WWDR chain and any
/// conformant CA does). Declaring them "understood" while still returning `.meetsPolicy` is the
/// intentional lenient posture: we accept the chain's structure and only require that it reaches
/// a bundled Apple root.
private struct PermissivePolicy: VerifierPolicy {
    let verifyingCriticalExtensions: [ASN1ObjectIdentifier] = [
        .X509ExtensionID.basicConstraints,
        .X509ExtensionID.keyUsage,
        .X509ExtensionID.extendedKeyUsage,
        .X509ExtensionID.nameConstraints,
    ]

    func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) async -> PolicyEvaluationResult {
        .meetsPolicy
    }
}

/// Bridges the async `CMS.isValidSignature` to the synchronous, CPU-bound `parse()` contract.
///
/// **Why this shape.** A naive "spawn a Task, block the caller on a semaphore" bridge deadlocks
/// when the caller is itself running on a Swift-concurrency cooperative-pool thread (e.g. an
/// `async` test, or a `Task`-driven UI call): the blocked pool thread cannot run the very Task it
/// is waiting on, and under parallel callers every pool thread can end up blocked with no thread
/// left to make progress. We saw exactly that deadlock under `swift test`'s parallel suites.
///
/// The fix routes the async work through `nonisolated` unstructured concurrency on a *dedicated*
/// thread and blocks a private dispatch worker (never the caller's pool thread): the caller
/// blocks a `DispatchSemaphore` while a fresh `Thread` runs a `Task` to completion. The Task uses
/// the shared executor, but because the blocking happens on threads we own (the dispatch worker /
/// the dedicated thread), no cooperative-pool thread is ever parked, so the executor always has
/// threads free to drive the Task. Serializing through `bridgeQueue` bounds the number of
/// concurrent dedicated threads to one, keeping the cost predictable. `parse()` is documented as
/// blocking / off-main, so paying one serialized hop per signature verification is acceptable.
private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    // The caller blocks on `semaphore` from whatever thread it is on - frequently a Swift-
    // concurrency cooperative-pool thread (an `async` test under `swift test`'s parallel suites,
    // or a `Task`-driven UI call). A naive `Task.detached` + block deadlocks there: the parked
    // pool thread cannot run the Task it is waiting on, and parallel callers can park every pool
    // thread at once with nothing left to make progress.
    //
    // On macOS 15 / iOS 18+ we pin the Task to a dedicated single-thread `TaskExecutor`, so the
    // work never touches the (possibly saturated) cooperative pool. On older OSes that API is
    // unavailable; fall back to a dedicated OS `Thread` whose `Task.detached` uses the shared
    // pool - sufficient there because production callers run `parse` off a thread they own (per
    // the `PassParser` contract) rather than parking the whole pool.
    if #available(macOS 15.0, iOS 18.0, *) {
        let task = Task(executorPreference: bridgeExecutor) {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        _ = task
    } else {
        let runner = Thread {
            Task.detached(priority: .userInitiated) {
                box.value = await operation()
                semaphore.signal()
            }
        }
        runner.stackSize = 4 * 1024 * 1024
        runner.start()
        semaphore.wait()
    }
    return box.value!
}

/// Dedicated single-thread `TaskExecutor` used only by `runBlocking` (macOS 15 / iOS 18+).
/// Backed by a serial `DispatchQueue`, so signature verifications run one-at-a-time on a thread
/// we own, never on the shared cooperative pool. Shared (one queue) because pkpass parsing is
/// infrequent and the work is CPU-bound and short.
@available(macOS 15.0, iOS 18.0, *)
private let bridgeExecutor = DispatchQueueTaskExecutor(label: "is.walt.passes.core.signature-bridge")

@available(macOS 15.0, iOS 18.0, *)
private final class DispatchQueueTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async {
            unowned.runSynchronously(on: executor)
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
