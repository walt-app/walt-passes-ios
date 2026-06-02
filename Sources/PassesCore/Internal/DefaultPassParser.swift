import Foundation

/// The single concrete `PassParser`. Stitches the security-critical slices (`extractSafely`,
/// `verifyManifest`, `verifySignature`, `decodePassJson`) plus `parseStrings` and
/// `readPngDimensions` into a non-throwing pipeline whose every error path lands on a
/// `ParseResult` arm.
///
/// **Pipeline order is load-bearing.** It mirrors the trust hierarchy the public surface
/// partitions along: structural validity (extract) -> integrity binding (manifest hash chain) ->
/// cryptographic provenance (signature) -> semantic content (pass.json, strings, images).
/// Reordering any earlier step past a later one would let a structural attack surface as a
/// tampering / unsupported reason or vice versa, mis-routing the trust UI.
///
/// **Concurrency.** Stateless beyond the immutable `ParserConfig`; every helper takes the
/// work-in-progress entries as parameters, so one instance is safe to call from any number of
/// threads concurrently.
///
/// **Telemetry.** Android brackets `parse` with telemetry; the iOS `ParserConfig` has no
/// telemetry guard, so all telemetry calls are dropped from this port.
internal struct DefaultPassParser: PassParser {
    private let config: ParserConfig

    init(config: ParserConfig) {
        self.config = config
    }

    func parse(source: PassSource) -> ParseResult {
        runPipeline(source)
    }

    private func runPipeline(_ source: PassSource) -> ParseResult {
        let entries: [(name: String, bytes: [UInt8])]
        switch extractSafely(source, config: config) {
        case .failure(let reason): return .malformed(reason: reason)
        case .success(let e, _): entries = e
        }

        let manifestBytes: [UInt8]
        switch verifyManifest(entries) {
        case .failed(let failure): return manifestFailureToResult(failure)
        case .ok(let bytes): manifestBytes = bytes
        }

        let signatureStatus: SignatureStatus
        switch resolveSignature(entries, manifestBytes: manifestBytes) {
        case .halt(let result): return result
        case .cont(let status): signatureStatus = status
        }

        let pass: Pass
        switch decodePassJson(entries, config: config) {
        case .failed(let failure): return passJsonFailureToResult(failure)
        case .ok(let p): pass = p
        }

        let locales: [PassLocale: LocalizedStrings]
        switch collectLocales(entries) {
        case .halt(let result): return result
        case .cont(let value): locales = value
        }

        let images: [ImageRole: ImageBytes]
        switch collectImages(entries) {
        case .halt(let result): return result
        case .cont(let value): images = value
        }

        let assembled = Pass(
            type: pass.type,
            serialNumber: pass.serialNumber,
            description: pass.description,
            organizationName: pass.organizationName,
            expirationDate: pass.expirationDate,
            voided: pass.voided,
            colors: pass.colors,
            frontFields: pass.frontFields,
            backFields: pass.backFields,
            barcode: pass.barcode,
            images: images,
            locales: locales
        )
        return .success(pass: assembled, signatureStatus: signatureStatus)
    }

    private func resolveSignature(
        _ entries: [(name: String, bytes: [UInt8])],
        manifestBytes: [UInt8]
    ) -> Phase<SignatureStatus> {
        guard let signatureBytes = entries.first(where: { $0.name == SIGNATURE_FILE_NAME })?.bytes else {
            // No signature blob. Lenient default surfaces `.unsigned`; strict mode treats absence
            // as a security event, routed through `.signatureCryptoFailure` (same category of
            // refusal as "the bytes did not parse as a CMS envelope").
            return config.acceptUnsignedArchives
                ? .cont(.unsigned)
                : .halt(.tampered(reason: .signatureCryptoFailure))
        }
        switch verifySignature(signatureBytes: signatureBytes, manifestBytes: manifestBytes, config: config) {
        case .ok(let status): return .cont(status)
        case .failed(let reason): return .halt(.tampered(reason: reason))
        }
    }

    private func collectLocales(_ entries: [(name: String, bytes: [UInt8])]) -> Phase<[PassLocale: LocalizedStrings]> {
        // Two-pass: identify locale-bearing names so the cap fires before any .strings parsing.
        let stringsEntries = entries.compactMap { entry -> (locale: String, bytes: [UInt8])? in
            guard let locale = lprojStringsLocale(entry.name) else { return nil }
            return (locale, entry.bytes)
        }
        if stringsEntries.count > config.maxLocaleCount {
            return .halt(.malformed(reason: .resourceLimitExceeded(limit: .localeCount)))
        }
        var map: [PassLocale: LocalizedStrings] = [:]
        for entry in stringsEntries {
            switch parseStrings(entry.bytes, config: config) {
            case .ok(let strings): map[PassLocale(entry.locale)] = strings
            case .failed(let failure): return .halt(stringsFailureToResult(failure))
            }
        }
        return .cont(map)
    }

    private func collectImages(_ entries: [(name: String, bytes: [UInt8])]) -> Phase<[ImageRole: ImageBytes]> {
        // Pre-filter to top-level role images. Localized images (under `<locale>.lproj/`) are
        // silently dropped - the renderer consumes only the top-level role images today.
        var map: [ImageRole: ImageBytes] = [:]
        for entry in entries {
            guard let role = topLevelImageRole(entry.name) else { continue }
            if let limitTrip = pngPixelLimitFailure(entry.bytes) {
                return .halt(limitTrip)
            }
            map[role] = ImageBytes(bytes: Data(entry.bytes))
        }
        return .cont(map)
    }

    private func topLevelImageRole(_ name: String) -> ImageRole? {
        let isTopLevelPng = !name.contains("/") && name.lowercased().hasSuffix(PNG_EXTENSION)
        return isTopLevelPng ? ROLE_BY_BASENAME[name.lowercased()] : nil
    }

    private func pngPixelLimitFailure(_ bytes: [UInt8]) -> ParseResult? {
        // A PNG whose IHDR is unreadable skips the pixel cap rather than being treated as
        // malformed: the bytes are inert here and per-entry size is already bounded upstream.
        guard let dim = readPngDimensions(bytes) else { return nil }
        let limit = Int64(config.maxImagePixelCount)
        // Axis pre-check rules out signed-Int64 overflow on width*height: if either axis already
        // exceeds the cap the product does too; otherwise both are <= limit and the product fits.
        let exceedsAxis = dim.width > limit || dim.height > limit
        let exceedsProduct = !exceedsAxis && dim.width * dim.height > limit
        guard exceedsAxis || exceedsProduct else { return nil }
        return .malformed(reason: .resourceLimitExceeded(limit: .imagePixelCount))
    }
}

/// Continuation outcome of a pipeline stage that can short-circuit with a pre-baked `ParseResult`.
private enum Phase<T> {
    case cont(T)
    case halt(ParseResult)
}

/// The hash-mismatch arm is the only manifest failure that constitutes tampering. Every other
/// arm collapses onto `missingManifest` / `invalidManifest`, mirroring Android.
private func manifestFailureToResult(_ failure: ManifestFailure) -> ParseResult {
    switch failure {
    case .missing: return .malformed(reason: .missingManifest)
    case .hashMismatch: return .tampered(reason: .fileHashMismatch)
    case .invalidJson, .invalidShape, .invalidHashFormat, .selfReferentialEntry, .extraEntry, .missingEntry:
        return .malformed(reason: .invalidManifest)
    }
}

private func passJsonFailureToResult(_ failure: PassJsonFailure) -> ParseResult {
    switch failure {
    case .missing: return .malformed(reason: .missingPassJson)
    case .invalidJson, .invalidShape: return .malformed(reason: .invalidPassJson)
    case .jsonDepthExceeded: return .malformed(reason: .resourceLimitExceeded(limit: .jsonDepth))
    case .jsonStringTooLong: return .malformed(reason: .resourceLimitExceeded(limit: .jsonStringSize))
    case .unknownFormatVersion(let version): return .unsupported(reason: .formatVersion(version: version))
    case .unknownPassStyle(let raw): return .unsupported(reason: .unknownPassStyle(raw: raw))
    }
}

private func stringsFailureToResult(_ failure: StringsFailure) -> ParseResult {
    switch failure {
    case .valueTooLong: return .malformed(reason: .resourceLimitExceeded(limit: .jsonStringSize))
    case .invalidEncoding, .unterminatedString, .unterminatedComment, .badStructure, .badEscape:
        return .malformed(reason: .invalidStrings)
    }
}

private func lprojStringsLocale(_ name: String) -> String? {
    // A valid PKPASS keeps locale dirs at the archive root, so the locale segment must be
    // non-empty and slash-free. Path traversal is already rejected upstream.
    guard name.hasSuffix(LPROJ_STRINGS_SUFFIX) else { return nil }
    let locale = String(name.dropLast(LPROJ_STRINGS_SUFFIX.count))
    return (locale.isEmpty || locale.contains("/")) ? nil : locale
}

private let ROLE_BY_BASENAME: [String: ImageRole] = [
    "logo.png": .logo,
    "logo@2x.png": .logoRetina,
    "logo@3x.png": .logoSuperRetina,
    "icon.png": .icon,
    "icon@2x.png": .iconRetina,
    "icon@3x.png": .iconSuperRetina,
    "strip.png": .strip,
    "strip@2x.png": .stripRetina,
    "strip@3x.png": .stripSuperRetina,
    "background.png": .background,
    "background@2x.png": .backgroundRetina,
    "background@3x.png": .backgroundSuperRetina,
    "thumbnail.png": .thumbnail,
    "thumbnail@2x.png": .thumbnailRetina,
    "thumbnail@3x.png": .thumbnailSuperRetina,
    "footer.png": .footer,
    "footer@2x.png": .footerRetina,
    "footer@3x.png": .footerSuperRetina,
]

private let PNG_EXTENSION = ".png"
private let LPROJ_STRINGS_SUFFIX = ".lproj/pass.strings"
