import Compression
import Foundation

/// Minimal, in-memory ZIP reader. **Platform mapping**: Swift/Foundation ships no ZIP reader,
/// so where Android leans on `java.util.zip.ZipInputStream` this hand-rolls the format over
/// Apple's `Compression` framework. It parses the End-Of-Central-Directory record, walks the
/// central-directory file headers, then reads each local header and inflates stored (method 0)
/// or DEFLATE (method 8) entries. Apple's `COMPRESSION_ZLIB` is raw DEFLATE, exactly ZIP
/// method 8.
///
/// Scope, mirrored against the pkpass threat model rather than a general unzip: ZIP64,
/// data-descriptor-only entries (general-purpose bit 3 set), and encrypted entries are
/// rejected as `notAZipArchive`. Real pkpass files are small standard zips, so this is a
/// documented, deliberate limitation rather than a gap. The size / count / name / duplicate
/// guards live in `SafeArchiveExtractor`, which drives this reader entry-by-entry; this type
/// only knows the format.
internal enum ZipReader {
    /// A single central-directory entry resolved to its decompressed bytes. Order matches the
    /// central directory, which a conformant writer keeps in local-file-header order, so the
    /// downstream manifest hash chain iterates deterministically (mirrors the Android
    /// insertion-ordered map contract).
    internal struct Entry {
        let name: String
        let bytes: [UInt8]
    }

    internal enum ReadError: Error {
        /// Structurally not a parseable zip (bad EOCD, truncated header, bad signature) or an
        /// unsupported shape we map to `notAZipArchive` (ZIP64, data-descriptor, encryption,
        /// unknown compression method).
        case notAZip
        /// A single entry's decompressed size exceeded `maxEntryBytes`. Carries the entry name
        /// so the caller can keep the per-entry size-limit arm.
        case entryTooLarge(name: String)
    }

    /// Decodes every file entry. `perEntryByteLimit` bounds each entry's decompressed size; an
    /// entry past it throws `entryTooLarge` so the caller surfaces the resource-limit arm. The
    /// reader does not enforce archive-size / entry-count / name caps - those are the
    /// extractor's job.
    static func read(_ data: [UInt8], perEntryByteLimit: Int64) throws -> [Entry] {
        let eocd = try findEndOfCentralDirectory(data)
        var entries: [Entry] = []
        var offset = eocd.centralDirectoryOffset
        for _ in 0..<eocd.entryCount {
            let (header, next) = try parseCentralDirectoryHeader(data, at: offset)
            let bytes = try readLocalEntry(data, header: header, perEntryByteLimit: perEntryByteLimit)
            entries.append(Entry(name: header.name, bytes: bytes))
            offset = next
        }
        return entries
    }

    // MARK: - End of central directory

    private struct EndOfCentralDirectory {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    /// Scans backward for the EOCD signature (`PK\x05\x06`). The record is 22 bytes plus a
    /// variable comment, so the signature can sit anywhere in the trailing 22 + 65535 bytes.
    private static func findEndOfCentralDirectory(_ data: [UInt8]) throws -> EndOfCentralDirectory {
        let minRecord = 22
        guard data.count >= minRecord else { throw ReadError.notAZip }
        let maxComment = 0xFFFF
        let searchFloor = max(0, data.count - minRecord - maxComment)
        var i = data.count - minRecord
        while i >= searchFloor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                let totalEntries = readU16(data, i + 10)
                let entriesOnDisk = readU16(data, i + 8)
                // A ZIP64 archive stores 0xFFFF here and puts the real count in the ZIP64
                // EOCD record, which this reader does not parse. Treat as unsupported.
                if totalEntries == 0xFFFF || entriesOnDisk == 0xFFFF { throw ReadError.notAZip }
                let cdOffset = readU32(data, i + 16)
                if cdOffset == 0xFFFF_FFFF { throw ReadError.notAZip }
                guard cdOffset <= data.count else { throw ReadError.notAZip }
                return EndOfCentralDirectory(entryCount: totalEntries, centralDirectoryOffset: cdOffset)
            }
            i -= 1
        }
        throw ReadError.notAZip
    }

    // MARK: - Central directory

    private struct CentralHeader {
        let name: String
        let compressionMethod: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let generalPurposeFlags: Int
    }

    /// Parses one central-directory file header and returns it plus the offset of the next.
    private static func parseCentralDirectoryHeader(
        _ data: [UInt8],
        at offset: Int
    ) throws -> (CentralHeader, Int) {
        let fixed = 46
        guard offset + fixed <= data.count else { throw ReadError.notAZip }
        guard data[offset] == 0x50, data[offset + 1] == 0x4B, data[offset + 2] == 0x01,
            data[offset + 3] == 0x02
        else { throw ReadError.notAZip }
        let flags = readU16(data, offset + 8)
        let method = readU16(data, offset + 10)
        let compressedSize = readU32(data, offset + 20)
        let uncompressedSize = readU32(data, offset + 24)
        let nameLen = readU16(data, offset + 28)
        let extraLen = readU16(data, offset + 30)
        let commentLen = readU16(data, offset + 32)
        let localOffset = readU32(data, offset + 42)
        let nameStart = offset + fixed
        guard nameStart + nameLen <= data.count else { throw ReadError.notAZip }
        // ZIP64 stuffs 0xFFFFFFFF sentinels into the size / offset fields; unsupported here.
        let hasZip64Sentinel =
            compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF
            || localOffset == 0xFFFF_FFFF
        if hasZip64Sentinel {
            throw ReadError.notAZip
        }
        guard let name = decodeEntryName(Array(data[nameStart..<nameStart + nameLen]), flags: flags)
        else { throw ReadError.notAZip }
        let next = nameStart + nameLen + extraLen + commentLen
        let header = CentralHeader(
            name: name,
            compressionMethod: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localOffset,
            generalPurposeFlags: flags
        )
        return (header, next)
    }

    /// Entry names are UTF-8 when the language-encoding flag (bit 11) is set; otherwise PKWARE
    /// historically used CP437. pkpass writers emit ASCII names, which is a subset of both, so
    /// decoding as UTF-8 and falling back to a Latin-1 mapping covers every real case without a
    /// CP437 table. A name that is not valid UTF-8 nor representable returns `nil` -> notAZip.
    private static func decodeEntryName(_ bytes: [UInt8], flags: Int) -> String? {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    // MARK: - Local entry

    /// Reads the local file header at the central-directory-declared offset, then inflates the
    /// entry. The local header is re-read (rather than trusting the central directory's sizes
    /// alone) because the compressed bytes follow it; sizes come from the central directory,
    /// which is the authoritative copy in a conformant zip.
    private static func readLocalEntry(
        _ data: [UInt8],
        header: CentralHeader,
        perEntryByteLimit: Int64
    ) throws -> [UInt8] {
        // A data-descriptor-only entry (general-purpose bit 3) carries zero sizes in the local
        // header and defers them to a trailing descriptor; the central directory still holds
        // the real sizes, so we tolerate the flag but rely on the central-directory sizes.
        let fixed = 30
        let lo = header.localHeaderOffset
        guard lo + fixed <= data.count else { throw ReadError.notAZip }
        guard data[lo] == 0x50, data[lo + 1] == 0x4B, data[lo + 2] == 0x03, data[lo + 3] == 0x04
        else { throw ReadError.notAZip }
        // Encryption (general-purpose bit 0) is unsupported.
        if header.generalPurposeFlags & 0x1 != 0 { throw ReadError.notAZip }
        let nameLen = readU16(data, lo + 26)
        let extraLen = readU16(data, lo + 28)
        let dataStart = lo + fixed + nameLen + extraLen
        guard dataStart + header.compressedSize <= data.count else { throw ReadError.notAZip }
        // Cap the declared decompressed size before allocating the inflate buffer; a zip-bomb
        // entry declaring a huge uncompressed size is rejected here, not after expansion.
        if Int64(header.uncompressedSize) > perEntryByteLimit {
            throw ReadError.entryTooLarge(name: header.name)
        }
        let compressed = Array(data[dataStart..<dataStart + header.compressedSize])
        switch header.compressionMethod {
        case 0:
            // Stored. The compressed and uncompressed sizes must agree.
            guard header.compressedSize == header.uncompressedSize else { throw ReadError.notAZip }
            return compressed
        case 8:
            return try inflate(
                compressed,
                expectedSize: header.uncompressedSize,
                name: header.name,
                perEntryByteLimit: perEntryByteLimit
            )
        default:
            throw ReadError.notAZip
        }
    }

    /// Raw-DEFLATE inflate via `compression_decode_buffer` with `COMPRESSION_ZLIB`. The
    /// destination buffer is sized to the central-directory's declared uncompressed size (one
    /// pass, no growth loop) - already bounded by `perEntryByteLimit` above. A zero-length
    /// entry short-circuits because `compression_decode_buffer` returns 0 both for "produced
    /// nothing" and "buffer too small," which would otherwise be ambiguous.
    private static func inflate(
        _ compressed: [UInt8],
        expectedSize: Int,
        name: String,
        perEntryByteLimit: Int64
    ) throws -> [UInt8] {
        if expectedSize == 0 { return [] }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = destination.withUnsafeMutableBufferPointer { dst -> Int in
            compressed.withUnsafeBufferPointer { src in
                compression_decode_buffer(
                    dst.baseAddress!, dst.count,
                    src.baseAddress!, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        // A short or zero write means the declared size was wrong or the stream was corrupt.
        guard written == expectedSize else { throw ReadError.notAZip }
        if Int64(written) > perEntryByteLimit { throw ReadError.entryTooLarge(name: name) }
        return destination
    }

    // MARK: - Little-endian readers

    private static func readU16(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) | (Int(b[off + 1]) << 8)
    }

    private static func readU32(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
    }
}
