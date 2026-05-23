import Foundation
import Testing

@testable import PassesPDFCore

/// Pins the magic-byte gate that runs before the renderer ever sees an input. The test
/// matrix walks the version range accepted, the version ranges rejected, and the
/// non-PDF formats most likely to be MIME-spoofed by an attacker (ZIP because pkpass is
/// also a ZIP, then PNG/JPEG/EXE as common cover formats).
@Suite("PDFHeaderSniffer")
struct PDFHeaderSnifferTests {

    @Test func acceptsMinimumPdf1Header() {
        #expect(isPDFHeader(Data("%PDF-1.0".utf8)))
    }

    @Test func acceptsMaximumPdf2Header() {
        #expect(isPDFHeader(Data("%PDF-2.0".utf8)))
    }

    @Test func acceptsTrailingDataAfterTheEightByteHeader() {
        // Body is non-ASCII, but the first 8 bytes are pure ASCII and that's all
        // that matters to the sniff.
        var withBody = Data("%PDF-1.7\n".utf8)
        withBody.append(contentsOf: [0x25, 0xA5, 0xB1, 0xEB, 0x0A, 0x31, 0x20, 0x30])
        #expect(isPDFHeader(withBody))
    }

    @Test func acceptsEveryPdf1MinorVersion() {
        for minor in 0...9 {
            let header = Data("%PDF-1.\(minor)".utf8)
            #expect(isPDFHeader(header), "minor=\(minor)")
        }
    }

    @Test func rejectsLeadingWhitespace() {
        #expect(!isPDFHeader(Data(" %PDF-1.0".utf8)))
        #expect(!isPDFHeader(Data("\n%PDF-1.0".utf8)))
        #expect(!isPDFHeader(Data("\t%PDF-1.0".utf8)))
    }

    @Test func rejectsLowercaseAndPartialMagic() {
        #expect(!isPDFHeader(Data("%pdf-1.0".utf8)))
        #expect(!isPDFHeader(Data("%PDF1.0 ".utf8)))
    }

    @Test func rejectsMajorVersionsOutsideOneAndTwo() {
        #expect(!isPDFHeader(Data("%PDF-0.9".utf8)))
        #expect(!isPDFHeader(Data("%PDF-3.0".utf8)))
        #expect(!isPDFHeader(Data("%PDF-9.9".utf8)))
    }

    @Test func rejectsMissingDot() {
        #expect(!isPDFHeader(Data("%PDF-1A0".utf8)))
    }

    @Test func rejectsNonDigitMinor() {
        #expect(!isPDFHeader(Data("%PDF-1.A".utf8)))
    }

    @Test func rejectsNonPdfFormats() {
        // ZIP/PKPASS local-file-header magic.
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])
        #expect(!isPDFHeader(zip))

        // PNG signature.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(!isPDFHeader(png))

        // JPEG SOI + JFIF marker.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        #expect(!isPDFHeader(jpeg))

        // PE/EXE.
        let exe = Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00])
        #expect(!isPDFHeader(exe))
    }

    @Test func rejectsInputsShorterThanEightBytes() {
        #expect(!isPDFHeader(Data()))
        #expect(!isPDFHeader(Data("%PDF-1.".utf8)))
        #expect(!isPDFHeader(Data("%PDF".utf8)))
    }
}
