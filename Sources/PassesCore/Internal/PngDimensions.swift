import Foundation

/// Decoded PNG canvas dimensions read from the IHDR chunk. Both fields are widened to `Int64`
/// because PNG's IHDR encodes width and height as unsigned 32-bit integers; a signed 32-bit
/// `Int` would mis-classify any value with the high bit set as negative and a subsequent
/// `width * height` would overflow before the resource-limit check ran.
internal struct PngDimensions: Equatable {
    let width: Int64
    let height: Int64
}

/// Reads the IHDR chunk of a PNG to recover its declared canvas dimensions. Used only by the
/// image-pixel-count guard in the parser-glue layer: PKPASS images are PNG-only, and the cap
/// that matters there is "renderer memory after decompression," not the on-disk byte size the
/// extractor already bounds.
///
/// Returns `nil` for any input that does not begin with the PNG 8-byte signature followed by an
/// IHDR chunk type at the documented offset, or whose declared dimensions are non-positive. The
/// glue layer treats `nil` as "skip the pixel cap for this entry" - a malformed PNG is upstream
/// content the parser does not pretend to validate past the resource-bound; the renderer will
/// surface its own decode failure.
///
/// Byte-level rather than a CoreGraphics decode: a real decode would materialize the full pixel
/// array before the cap could fire, exactly the failure mode the cap exists to prevent. The
/// IHDR-only read pulls 24 bytes regardless of declared dimensions.
internal func readPngDimensions(_ bytes: [UInt8]) -> PngDimensions? {
    let structurallyAPng =
        bytes.count >= pngHeaderPlusIhdrLength
        && hasPngSignature(bytes)
        && isIhdrChunkType(bytes)
    guard structurallyAPng else { return nil }
    let width = readU32BigEndian(bytes, ihdrWidthOffset)
    let height = readU32BigEndian(bytes, ihdrHeightOffset)
    return (width <= 0 || height <= 0) ? nil : PngDimensions(width: width, height: height)
}

private func hasPngSignature(_ bytes: [UInt8]) -> Bool {
    for i in pngSignature.indices where bytes[i] != pngSignature[i] {
        return false
    }
    return true
}

private func isIhdrChunkType(_ bytes: [UInt8]) -> Bool {
    bytes[ihdrTypeOffset] == UInt8(ascii: "I")
        && bytes[ihdrTypeOffset + 1] == UInt8(ascii: "H")
        && bytes[ihdrTypeOffset + 2] == UInt8(ascii: "D")
        && bytes[ihdrTypeOffset + 3] == UInt8(ascii: "R")
}

private func readU32BigEndian(_ b: [UInt8], _ off: Int) -> Int64 {
    let b0 = Int64(b[off]) & 0xFF
    let b1 = Int64(b[off + 1]) & 0xFF
    let b2 = Int64(b[off + 2]) & 0xFF
    let b3 = Int64(b[off + 3]) & 0xFF
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private let ihdrTypeOffset = 12
private let ihdrWidthOffset = 16
private let ihdrHeightOffset = 20
private let pngHeaderPlusIhdrLength = 24
