import Foundation

private let headerLength = 8

/// Header-sniff for the PDF magic. Returns true iff the supplied bytes begin with the
/// 8-byte sequence `%PDF-X.Y` where `X` is `1` or `2` and `Y` is any ASCII digit.
///
/// This is the structural gate that runs *before* the renderer is even handed the
/// input, so a MIME-spoofed file (ZIP, image, executable) can be rejected with
/// `DocumentRejectedKind.notAPdf` without ever entering the decoder. Versions 1.x
/// (PDFs in the wild) and 2.x (the 2017+ ISO 32000-2 lineage) are accepted; everything
/// else - including PDFs with leading whitespace, which are explicitly out-of-spec at
/// the file-header level even though some forgiving parsers tolerate them - is rejected.
///
/// Anchoring to the very first byte (rather than searching the first 1024 bytes for the
/// marker, as some other tools do) is a *deliberate* deviation: the search-anchored
/// variant exists precisely because some older PDFs emit junk before the header, and
/// accepting that hands an attacker a place to hide a payload that the renderer might
/// still parse. The gain is refused and the surface kept tight.
public func isPDFHeader(_ bytes: Data) -> Bool {
    guard bytes.count >= headerLength else { return false }
    let b = [UInt8](bytes.prefix(headerLength))
    let percent: UInt8 = 0x25 // '%'
    let cP: UInt8 = 0x50      // 'P'
    let cD: UInt8 = 0x44      // 'D'
    let cF: UInt8 = 0x46      // 'F'
    let dash: UInt8 = 0x2D    // '-'
    let one: UInt8 = 0x31     // '1'
    let two: UInt8 = 0x32     // '2'
    let dot: UInt8 = 0x2E     // '.'
    let zero: UInt8 = 0x30    // '0'
    let nine: UInt8 = 0x39    // '9'
    return b[0] == percent &&
        b[1] == cP &&
        b[2] == cD &&
        b[3] == cF &&
        b[4] == dash &&
        (b[5] == one || b[5] == two) &&
        b[6] == dot &&
        (b[7] >= zero && b[7] <= nine)
}
