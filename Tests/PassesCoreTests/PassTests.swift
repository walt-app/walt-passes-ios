import Foundation
import Testing

@testable import PassesCore

@Suite("Pass")
struct PassTests {

    private func sample(
        type: PassType = .generic,
        serialNumber: String = "SN-1",
        organizationName: String = "Walt",
        description: String = "desc",
        expirationDate: PassInstant? = nil,
        voided: Bool = false,
        colors: PassColors = PassColors(),
        frontFields: PassFields = PassFields(),
        backFields: [PassField] = [],
        barcode: Barcode? = nil,
        images: [ImageRole: ImageBytes] = [:],
        locales: [PassLocale: LocalizedStrings] = [:]
    ) -> Pass {
        Pass(
            type: type,
            serialNumber: serialNumber,
            description: description,
            organizationName: organizationName,
            expirationDate: expirationDate,
            voided: voided,
            colors: colors,
            frontFields: frontFields,
            backFields: backFields,
            barcode: barcode,
            images: images,
            locales: locales
        )
    }

    // ---- value equality ----

    @Test func equalityCoversEveryField() {
        #expect(sample() == sample())
        #expect(sample(serialNumber: "A") != sample(serialNumber: "B"))
        #expect(sample(type: .generic) != sample(type: .boardingPass))
        #expect(sample(voided: false) != sample(voided: true))
    }

    @Test func imageBytesEqualityIsValueBased() {
        let bytes = Data([1, 2, 3])
        #expect(ImageBytes(bytes: bytes) == ImageBytes(bytes: Data([1, 2, 3])))
        #expect(ImageBytes(bytes: bytes) != ImageBytes(bytes: Data([1, 2, 4])))
    }

    @Test func defaultsMatchAndroid() {
        let p = sample()
        #expect(p.expirationDate == nil)
        #expect(p.voided == false)
        #expect(p.backFields.isEmpty)
        #expect(p.barcode == nil)
        #expect(p.images.isEmpty)
        #expect(p.locales.isEmpty)
    }

    // ---- locale fallback ----

    @Test func resolveLocalizedStringsExactMatch() {
        let p = sample(locales: [
            PassLocale("en-US"): LocalizedStrings(entries: ["k": "us"]),
            PassLocale("en-GB"): LocalizedStrings(entries: ["k": "gb"]),
        ])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("en-US")).entries["k"] == "us")
    }

    @Test func resolveLocalizedStringsLanguageOnlyFallback() {
        let p = sample(locales: [
            PassLocale("en"): LocalizedStrings(entries: ["k": "en"])
        ])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("en-US")).entries["k"] == "en")
    }

    @Test func resolveLocalizedStringsLanguageOnlyFallbackUnderscoreSplit() {
        let p = sample(locales: [
            PassLocale("sv"): LocalizedStrings(entries: ["k": "sv"])
        ])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("sv_FI")).entries["k"] == "sv")
    }

    @Test func resolveLocalizedStringsFallsBackToEnglish() {
        let p = sample(locales: [
            PassLocale("en"): LocalizedStrings(entries: ["k": "en"]),
            PassLocale("de"): LocalizedStrings(entries: ["k": "de"]),
        ])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("fr")).entries["k"] == "en")
    }

    @Test func resolveLocalizedStringsDeterministicFallback() {
        // No exact match, no language fallback, no `en` — pick lexicographically-smallest tag.
        let p = sample(locales: [
            PassLocale("de"): LocalizedStrings(entries: ["k": "de"]),
            PassLocale("zh"): LocalizedStrings(entries: ["k": "zh"]),
        ])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("fr")).entries["k"] == "de")
    }

    @Test func resolveLocalizedStringsEmptyMapReturnsEmpty() {
        let p = sample(locales: [:])
        #expect(p.resolveLocalizedStrings(preferred: PassLocale("en")) == LocalizedStrings.empty)
    }

    // ---- LocalizedStrings.lookupOrSelf ----

    @Test func lookupOrSelfReturnsMappedValue() {
        let s = LocalizedStrings(entries: ["k": "v"])
        #expect(s.lookupOrSelf("k") == "v")
    }

    @Test func lookupOrSelfReturnsRawWhenMissing() {
        let s = LocalizedStrings(entries: ["k": "v"])
        #expect(s.lookupOrSelf("missing") == "missing")
    }

    @Test func lookupOrSelfNullableReturnsNilForNil() {
        let s = LocalizedStrings(entries: ["k": "v"])
        #expect(s.lookupOrSelf(nil as String?) == nil)
    }

    @Test func lookupOrSelfNullablePassesThroughPresentValue() {
        let s = LocalizedStrings(entries: ["k": "v"])
        #expect(s.lookupOrSelf("k" as String?) == "v")
    }

    // ---- supporting types ----

    @Test func passFieldDefaults() {
        let f = PassField(key: "k", value: "v")
        #expect(f.label == nil)
        #expect(f.textAlignment == .natural)
    }

    @Test func passFieldsDefaultsAreEmpty() {
        let f = PassFields()
        #expect(f.header.isEmpty && f.primary.isEmpty && f.secondary.isEmpty && f.auxiliary.isEmpty)
    }

    @Test func passColorsAllNullable() {
        let c = PassColors()
        #expect(c.foreground == nil && c.background == nil && c.label == nil)
    }

    @Test func barcodeDefaultsAltTextToNil() {
        let b = Barcode(format: .qr, message: "x", messageEncoding: "iso-8859-1")
        #expect(b.altText == nil)
    }
}
