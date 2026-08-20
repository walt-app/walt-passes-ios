import Foundation

/// Byte-0-anchored magic sniff for the still-image containers the importer can
/// commit to (mirror of Android `ImageHeaderSniffer`). Check order: PNG, JPEG,
/// WebP. All checks are anchored to the very first byte — searching for the
/// magic elsewhere in the buffer (as some lenient parsers do) would let an
/// attacker prepend an arbitrary payload before the image data; anchoring
/// collapses that surface. HEIF/HEIC is deliberately absent: its `ftyp`-box
/// detection needs to read further than a fixed-offset magic check (and the
/// retained lane does not admit it anyway).
public func sniffImageFormat(_ bytes: Data) -> ImageFormat? {
    if isPngHeader(bytes) { return .png }
    if isJpegHeader(bytes) { return .jpeg }
    if isWebPHeader(bytes) { return .webp }
    return nil
}

/// The 8-byte PNG signature.
private func isPngHeader(_ bytes: Data) -> Bool {
    bytes.count >= 8
        && bytes.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

/// JPEG SOI + marker prefix. Byte 3 (the JFIF/EXIF/raw discriminator) is
/// intentionally NOT checked.
private func isJpegHeader(_ bytes: Data) -> Bool {
    bytes.count >= 3 && bytes[bytes.startIndex] == 0xFF
        && bytes[bytes.index(bytes.startIndex, offsetBy: 1)] == 0xD8
        && bytes[bytes.index(bytes.startIndex, offsetBy: 2)] == 0xFF
}

/// RIFF container with a WEBP fourcc; the 4-byte chunk size at [4..7] is
/// intentionally skipped.
private func isWebPHeader(_ bytes: Data) -> Bool {
    guard bytes.count >= 12 else { return false }
    let riff = bytes.prefix(4)
    let fourcc = bytes.dropFirst(8).prefix(4)
    return riff == Data("RIFF".utf8) && fourcc == Data("WEBP".utf8)
}
