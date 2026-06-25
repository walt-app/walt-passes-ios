import Foundation
import X509

@testable import PassesCore

/// Builds in-memory ZIP archives (and pkpass fixtures) for the parser tests. A minimal stored
/// (no compression) ZIP writer is enough: `ZipReader` handles method 0 and method 8 identically
/// once decompressed, and stored entries keep the fixtures deterministic and inspectable.
enum ZipBuilder {
    struct File {
        let name: String
        let bytes: [UInt8]
        init(_ name: String, _ bytes: [UInt8]) {
            self.name = name
            self.bytes = bytes
        }
        init(_ name: String, _ text: String) {
            self.name = name
            self.bytes = [UInt8](text.utf8)
        }
    }

    /// Produces a valid stored-method ZIP from `files`, in order.
    static func build(_ files: [File]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        var localOffsets: [Int] = []

        for file in files {
            localOffsets.append(out.count)
            let nameBytes = [UInt8](file.name.utf8)
            let crc = crc32(file.bytes)
            // Local file header.
            out += [0x50, 0x4B, 0x03, 0x04]  // signature
            out += u16(20)  // version needed
            out += u16(0)  // flags
            out += u16(0)  // method: stored
            out += u16(0)  // mod time
            out += u16(0)  // mod date
            out += u32(crc)
            out += u32(file.bytes.count)  // compressed size
            out += u32(file.bytes.count)  // uncompressed size
            out += u16(nameBytes.count)
            out += u16(0)  // extra len
            out += nameBytes
            out += file.bytes
        }

        let centralStart = out.count
        for (index, file) in files.enumerated() {
            let nameBytes = [UInt8](file.name.utf8)
            let crc = crc32(file.bytes)
            central += [0x50, 0x4B, 0x01, 0x02]  // central header signature
            central += u16(20)  // version made by
            central += u16(20)  // version needed
            central += u16(0)  // flags
            central += u16(0)  // method
            central += u16(0)  // mod time
            central += u16(0)  // mod date
            central += u32(crc)
            central += u32(file.bytes.count)
            central += u32(file.bytes.count)
            central += u16(nameBytes.count)
            central += u16(0)  // extra
            central += u16(0)  // comment
            central += u16(0)  // disk number
            central += u16(0)  // internal attrs
            central += u32(0)  // external attrs
            central += u32(localOffsets[index])
            central += nameBytes
        }
        out += central
        let centralSize = out.count - centralStart

        // End of central directory.
        out += [0x50, 0x4B, 0x05, 0x06]
        out += u16(0)  // disk
        out += u16(0)  // disk with CD
        out += u16(files.count)  // entries on disk
        out += u16(files.count)  // total entries
        out += u32(centralSize)
        out += u32(centralStart)
        out += u16(0)  // comment len
        return out
    }

    /// An empty but structurally valid ZIP (just an EOCD record).
    static func empty() -> [UInt8] {
        var out: [UInt8] = []
        out += [0x50, 0x4B, 0x05, 0x06]
        out += u16(0)
        out += u16(0)
        out += u16(0)
        out += u16(0)
        out += u32(0)
        out += u32(0)
        out += u16(0)
        return out
    }

    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u32(_ value: Int) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    /// Standard CRC-32 (zlib polynomial). ZIP requires it in both headers; `ZipReader` does not
    /// validate it, but writing a real value keeps fixtures spec-valid.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Helpers for assembling a manifest + signed/unsigned pkpass over a set of payload files.
enum PkpassFixtures {
    static func sha1Hex(_ bytes: [UInt8]) -> String {
        SignatureTestSupport.sha1Hex(bytes)
    }

    /// A minimal valid pass.json for the given style.
    static func passJson(style: String = "generic", extra: String = "") -> [UInt8] {
        let json = """
            {
              "formatVersion": 1,
              "serialNumber": "ABC123",
              "description": "Test pass",
              "organizationName": "Walt",
              "\(style)": { "primaryFields": [{ "key": "k", "value": "v" }] }\(extra)
            }
            """
        return [UInt8](json.utf8)
    }

    /// Builds a manifest.json declaring SHA-1 hashes for every supplied file (keyed by name).
    static func manifest(for files: [ZipBuilder.File]) -> [UInt8] {
        let entries = files.map { "  \"\($0.name)\": \"\(sha1Hex($0.bytes))\"" }.joined(separator: ",\n")
        return [UInt8]("{\n\(entries)\n}".utf8)
    }

    /// Assembles an unsigned pkpass (pass.json + manifest + payload files, no signature).
    static func unsignedArchive(payload: [ZipBuilder.File]) -> [UInt8] {
        let manifestBytes = manifest(for: payload)
        var files = payload
        files.append(ZipBuilder.File(manifestFileName, manifestBytes))
        return ZipBuilder.build(files)
    }

    /// Assembles a signed pkpass. The manifest is computed over `payload`, then CMS-signed.
    static func signedArchive(
        payload: [ZipBuilder.File],
        signer: SignatureTestSupport.Issued,
        intermediates: [Certificate] = []
    ) throws -> (archive: [UInt8], manifestBytes: [UInt8]) {
        let manifestBytes = manifest(for: payload)
        let signature = try SignatureTestSupport.sign(
            manifestBytes: manifestBytes,
            signer: signer,
            intermediates: intermediates
        )
        var files = payload
        files.append(ZipBuilder.File(manifestFileName, manifestBytes))
        files.append(ZipBuilder.File(signatureFileName, signature))
        return (ZipBuilder.build(files), manifestBytes)
    }
}
