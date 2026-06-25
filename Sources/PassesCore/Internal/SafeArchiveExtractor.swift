import Foundation

/// Outcome of running `extractSafely` over a `PassSource`. Internal only: the parser-glue layer
/// lifts a `failure` into `ParseResult.malformed`.
internal enum ExtractResult {
    /// Insertion-ordered name -> bytes map mirroring the archive's central-directory order so
    /// the downstream pass.json / manifest hash steps iterate deterministically. `archiveBytes`
    /// is the count of compressed-archive bytes the extractor consumed.
    case success(entries: [(name: String, bytes: [UInt8])], archiveBytes: Int64)
    case failure(reason: MalformedReason)
}

/// The single hardened ZIP-extraction entry point shared by PassesCore. Every guard the threat
/// model lists for untrusted PKPASS input is centralized here:
///
///  - **Magic-byte preflight.** The first 4 bytes must be a local-file-header (`PK\x03\x04`) or
///    an end-of-central-directory (`PK\x05\x06`, a legitimate empty archive) signature.
///    Anything else - raw garbage, 0-byte input - is rejected before any parsing.
///  - **Archive size** (compressed). Checked up front against the declared size
///    (`bytes.count` or `sizeHintBytes`). Because the iOS `ZipReader` works on a fully
///    in-memory `[UInt8]`, the materialized size is the authoritative compressed length; a
///    hostile `sizeHintBytes` cannot under-report past the materialization step.
///  - **Entry count.** `maxEntries` caps the number of file entries surfaced. Directory entries
///    are skipped before the count.
///  - **Per-entry decompressed size.** `maxEntryBytes` caps each entry; the zip-bomb guard. The
///    `ZipReader` rejects an over-cap entry before inflating it.
///  - **Path traversal (zip-slip).** `pathTraversalReason` rejects entry names with `..`/`.`
///    segments, leading `/`, backslashes, Windows drive prefixes, or empty segments. Structural
///    only - no file-system canonicalization, because nothing here ever touches the file system.
///  - **Symlink-shaped entries.** Extraction is in-memory only; entries land in a `[UInt8]` map
///    bounded by the per-entry cap, so a symlink-shaped name has no path to resolve. Combined
///    with the path-traversal check and extension allowlist this is sufficient for the trust
///    claim (mirrors the Android JDK-zip rationale).
///  - **Extension allowlist.** Names must end in `.json`, `.png`, or `.strings`, OR be exactly
///    `signature` at the archive root.
///  - **Duplicate entry names.** Rejected; a duplicate would let an attacker shadow a
///    legitimate `manifest.json`.
///  - **In-memory only.** No file output is ever opened.
///
/// Limit hits surface as `ResourceLimitExceeded` with the relevant `ResourceLimit`. Structural
/// rejections (path traversal, disallowed extension, duplicate name) surface as `notAZipArchive`,
/// mirroring Android's frozen `MalformedReason` surface.
internal func extractSafely(_ source: PassSource, config: ParserConfig) -> ExtractResult {
    let declaredSize: Int64?
    switch source {
    case .bytes(let data): declaredSize = Int64(data.count)
    case .stream(_, let hint): declaredSize = hint
    }
    if let declaredSize, declaredSize > config.maxArchiveBytes {
        return .failure(reason: .resourceLimitExceeded(limit: .archiveSize))
    }
    guard let bytes = materialize(source) else {
        return .failure(reason: .notAZipArchive)
    }
    // Re-check against the materialized length so a hostile under-reported size hint cannot slip
    // an oversized archive past the up-front check.
    if Int64(bytes.count) > config.maxArchiveBytes {
        return .failure(reason: .resourceLimitExceeded(limit: .archiveSize))
    }
    if let magicFailure = magicByteFailure(bytes) {
        return .failure(reason: magicFailure)
    }
    return runZipPipeline(bytes, config: config)
}

/// Reads a `PassSource` fully into memory. Returns `nil` if a stream read fails. The stream's
/// lifecycle is caller-owned (mirrors Android's `NonClosingInputStream`); the stream is opened
/// here only if not already open and is not closed.
private func materialize(_ source: PassSource) -> [UInt8]? {
    switch source {
    case .bytes(let data):
        return [UInt8](data)
    case .stream(let stream, _):
        if stream.streamStatus == .notOpen { stream.open() }
        var out = [UInt8]()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            out.append(contentsOf: buffer[0..<read])
        }
        return out
    }
}

/// Returns `notAZipArchive` if the leading 4 bytes are neither a local-file-header nor an
/// end-of-central-directory signature.
private func magicByteFailure(_ bytes: [UInt8]) -> MalformedReason? {
    guard bytes.count >= magicPrefixLength else { return .notAZipArchive }
    let head = Array(bytes[0..<magicPrefixLength])
    let matches = head == localFileHeaderMagic || head == endOfCentralDirMagic
    return matches ? nil : .notAZipArchive
}

private func runZipPipeline(_ bytes: [UInt8], config: ParserConfig) -> ExtractResult {
    let rawEntries: [ZipReader.Entry]
    do {
        rawEntries = try ZipReader.read(bytes, perEntryByteLimit: config.maxEntryBytes)
    } catch ZipReader.ReadError.entryTooLarge {
        return .failure(reason: .resourceLimitExceeded(limit: .entrySize))
    } catch {
        return .failure(reason: .notAZipArchive)
    }
    return assembleEntries(rawEntries, config: config, archiveBytes: Int64(bytes.count))
}

private func assembleEntries(
    _ rawEntries: [ZipReader.Entry],
    config: ParserConfig,
    archiveBytes: Int64
) -> ExtractResult {
    var entries: [(name: String, bytes: [UInt8])] = []
    var seen = Set<String>()
    for entry in rawEntries {
        // Validate the name unconditionally, even for directory entries skipped afterward, so a
        // future change that acts on them cannot bypass the path-traversal guard.
        if pathTraversalReason(entry.name) != nil {
            return .failure(reason: .notAZipArchive)
        }
        if entry.name.hasSuffix("/") { continue }  // directory entry
        if !hasAllowedName(entry.name) {
            return .failure(reason: .notAZipArchive)
        }
        if seen.contains(entry.name) {
            return .failure(reason: .notAZipArchive)
        }
        if entries.count >= config.maxEntries {
            return .failure(reason: .resourceLimitExceeded(limit: .entryCount))
        }
        seen.insert(entry.name)
        entries.append((name: entry.name, bytes: entry.bytes))
    }
    return .success(entries: entries, archiveBytes: archiveBytes)
}

private func pathTraversalReason(_ name: String) -> MalformedReason? {
    let chars = Array(name)
    let isWindowsAbsolute = chars.count >= 2 && chars[1] == ":"
    // Strip a single trailing `/` so a directory entry like "en.lproj/" doesn't trip the
    // empty-segment check on the trailing slot. Empty intermediate segments ("foo//bar") and a
    // bare "/" still fail.
    let canonical = String(name.reversed().drop(while: { $0 == "/" }).reversed())
    let segmentsUnsafe = canonical.split(separator: "/", omittingEmptySubsequences: false)
        .contains { $0 == ".." || $0 == "." || $0.isEmpty }
    let unsafe =
        name.isEmpty
        || canonical.hasPrefix("/")
        || canonical.contains("\\")
        || isWindowsAbsolute
        || (canonical != "" && segmentsUnsafe)
    return unsafe ? .notAZipArchive : nil
}

private func hasAllowedName(_ name: String) -> Bool {
    // The PKCS#7 signature file ("signature") is the only PKPASS member with no extension. Allow
    // it only at the archive root; a nested `nested/signature` is a disallowed-extension entry.
    if name == signatureFileName { return true }
    let baseName = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
    guard let lastDot = baseName.lastIndex(of: ".") else { return false }
    let ext = baseName[baseName.index(after: lastDot)...].lowercased()
    return allowedExtensions.contains(ext)
}

private let magicPrefixLength = 4
private let localFileHeaderMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
private let endOfCentralDirMagic: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
private let allowedExtensions: Set<String> = ["json", "png", "strings"]
