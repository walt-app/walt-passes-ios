import Crypto
import Foundation

/// Outcome of running `verifyManifest` over the entries map produced by `extractSafely`.
/// Internal only: the parser-glue layer lifts a `failed` into the right `ParseResult` arm.
/// `manifestBytes` are returned verbatim so the signature step hashes the exact bytes the PKCS#7
/// envelope was constructed over.
internal enum ManifestVerifyResult: Equatable {
    case ok(manifestBytes: [UInt8])
    case failed(ManifestFailure)
}

/// Why `verifyManifest` rejected an archive. `hashMismatch` is the only tampering signal - the
/// archive is structurally valid but a file's bytes differ from the declared SHA-1. Every other
/// arm is structural malformedness. Hash mismatches are NEVER coalesced with malformedness: the
/// trust UI must surface tampering as a security event, not "your file is broken."
internal enum ManifestFailure: Equatable {
    case missing
    case invalidJson
    case invalidShape
    case invalidHashFormat(entryName: String)
    case selfReferentialEntry
    case extraEntry(entryName: String)
    case missingEntry(entryName: String)
    case hashMismatch(entryName: String)
}

/// Verifies the SHA-1 hash chain a PKPASS archive declares in `manifest.json`. Pure function:
/// no I/O. `entries` is the ordered list produced by `extractSafely` on a successful run.
///
/// PKPASS uses SHA-1 here as a structural integrity check, not a cipher choice; the actual
/// cryptographic binding is the detached PKCS#7 signature over `manifest.json`'s bytes. SHA-1
/// here is required because every PKPASS writer in the wild emits it.
///
/// **Failure-arm ordering inside the per-entry loop** is load-bearing and matches Android:
///  1. `name == "signature"` -> `selfReferentialEntry` (structural rule beats hex validity)
///  2. hex parse fails -> `invalidHashFormat`
///  3. entry not in archive -> `missingEntry`
///  4. hash differs -> `hashMismatch`
/// After the loop, `extraEntry` surfaces the first archive entry not declared in the manifest
/// (`signature` and `manifest.json` exempt). The loop short-circuits, so `hashMismatch` beats
/// `extraEntry` when both could fire.
internal func verifyManifest(_ entries: [(name: String, bytes: [UInt8])]) -> ManifestVerifyResult {
    let byName = Dictionary(entries.map { ($0.name, $0.bytes) }, uniquingKeysWith: { first, _ in first })
    guard let manifestBytes = byName[manifestFileName] else {
        return .failed(.missing)
    }
    let failure: ManifestFailure?
    switch parseManifest(manifestBytes) {
    case .failed(let f): failure = f
    case .ok(let declared): failure = validateAllEntries(declared, entries: entries, byName: byName)
    }
    if let failure { return .failed(failure) }
    return .ok(manifestBytes: manifestBytes)
}

private enum ManifestParse {
    case ok([(key: String, value: String)])
    case failed(ManifestFailure)
}

private func parseManifest(_ manifestBytes: [UInt8]) -> ManifestParse {
    let object: [String: Any]
    do {
        guard let root = try JSONSerialization.jsonObject(with: Data(manifestBytes)) as? [String: Any] else {
            return .failed(.invalidShape)
        }
        object = root
    } catch {
        return .failed(.invalidJson)
    }
    // Preserve insertion order. JSONSerialization drops it, so re-derive a stable order by
    // walking the raw JSON for top-level keys. Order matters only for deterministic failure
    // naming; correctness of accept/reject does not depend on it.
    var declared: [(key: String, value: String)] = []
    for key in orderedTopLevelKeys(manifestBytes, fallback: Array(object.keys)) {
        guard let raw = object[key] else { continue }
        guard let str = raw as? String else { return .failed(.invalidShape) }
        declared.append((key: key, value: str))
    }
    return .ok(declared)
}

/// Recovers top-level object keys in source order. JSONSerialization gives an unordered dict, so
/// for deterministic first-failure naming this scans the raw bytes for the first occurrence of
/// each key. Falls back to the dict's keys if scanning misses any (correctness is unaffected;
/// only failure-name determinism rides on order).
private func orderedTopLevelKeys(_ bytes: [UInt8], fallback: [String]) -> [String] {
    guard let text = String(bytes: bytes, encoding: .utf8) else { return fallback }
    var ordered: [(key: String, pos: Int)] = []
    for key in fallback {
        if let range = text.range(of: "\"\(key)\"") {
            ordered.append((key: key, pos: text.distance(from: text.startIndex, to: range.lowerBound)))
        } else {
            ordered.append((key: key, pos: Int.max))
        }
    }
    return ordered.sorted { $0.pos < $1.pos }.map(\.key)
}

private func validateAllEntries(
    _ declared: [(key: String, value: String)],
    entries: [(name: String, bytes: [UInt8])],
    byName: [String: [UInt8]]
) -> ManifestFailure? {
    for (name, hexHash) in declared {
        if let failure = perEntryFailure(name: name, hexHash: hexHash, byName: byName) {
            return failure
        }
    }
    return findExtraEntry(declared: Set(declared.map(\.key)), entries: entries)
}

private func perEntryFailure(name: String, hexHash: String, byName: [String: [UInt8]]) -> ManifestFailure? {
    if name == signatureFileName { return .selfReferentialEntry }
    guard let expected = decodeSha1Hex(hexHash) else {
        return .invalidHashFormat(entryName: name)
    }
    guard let actual = byName[name] else {
        return .missingEntry(entryName: name)
    }
    let digest = Array(Insecure.SHA1.hash(data: Data(actual)))
    return constantTimeEqual(digest, expected) ? nil : .hashMismatch(entryName: name)
}

private func findExtraEntry(declared: Set<String>, entries: [(name: String, bytes: [UInt8])]) -> ManifestFailure? {
    for entry in entries
    where !declared.contains(entry.name) && entry.name != signatureFileName && entry.name != manifestFileName {
        return .extraEntry(entryName: entry.name)
    }
    return nil
}

/// Decodes a 40-character SHA-1 hex string to its 20 raw bytes, accepting any case. Returns
/// `nil` (not a throw) so the caller maps to `invalidHashFormat` without try/catch at each site.
private func decodeSha1Hex(_ hex: String) -> [UInt8]? {
    let chars = Array(hex)
    guard chars.count == sha1HexLength else { return nil }
    var out = [UInt8](repeating: 0, count: sha1HexLength / 2)
    var i = 0
    while i < sha1HexLength {
        guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
        out[i / 2] = UInt8((hi << 4) | lo)
        i += 2
    }
    return out
}

/// Constant-time byte compare. A plain `==` short-circuits on first mismatch and leaks a timing
/// oracle; for a hash compared against attacker-controlled bytes that is the textbook footgun.
/// Mirrors Android's `MessageDigest.isEqual`.
private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in a.indices { diff |= a[i] ^ b[i] }
    return diff == 0
}

private let sha1HexLength = 40
