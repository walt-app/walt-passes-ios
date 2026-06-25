import PassesCore
import Testing

@testable import PassesUI

@Suite("BarcodeCreateConfirmSheet")
struct BarcodeCreateConfirmSheetTests {

    @Test func plainTextSkipsTheGate() {
        let kind = BarcodeCreateConfirmSheet.barcodeCreateKind(of: .plainText)
        #expect(kind == nil)
    }

    @Test func urlMapsToUrl() {
        let kind = BarcodeCreateConfirmSheet.barcodeCreateKind(
            of: .url(scheme: "https", host: "example.com", raw: "https://example.com/login")
        )
        #expect(kind == .url)
    }

    @Test func phoneMapsToPhone() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .phone(number: "+1")) == .phone)
    }

    @Test func smsMapsToSms() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .sms(number: "+1")) == .sms)
    }

    @Test func mailtoMapsToMailto() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .mailto(address: "x@y")) == .mailto)
    }

    @Test func geoMapsToGeo() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .geo(coords: "0,0")) == .geo)
    }

    @Test func wifiMapsToWifi() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .wifi(ssid: "Acme")) == .wifi)
    }

    @Test func bitcoinMapsToBitcoin() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .bitcoin(address: "bc1")) == .bitcoin)
    }

    @Test func ethereumMapsToEthereum() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .ethereum(address: "0xa")) == .ethereum)
    }

    @Test func magnetMapsToMagnet() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .magnet) == .magnet)
    }

    @Test func marketMapsToMarket() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .market(productId: "id")) == .market)
    }

    @Test func intentMapsToIntent() {
        #expect(BarcodeCreateConfirmSheet.barcodeCreateKind(of: .intent(raw: "intent:#")) == .intent)
    }

    @Test func unknownSchemeMapsToUnknownScheme() {
        let kind = BarcodeCreateConfirmSheet.barcodeCreateKind(
            of: .unknownScheme(scheme: "foo", raw: "foo:bar")
        )
        #expect(kind == .unknownScheme)
    }

    @Test func plainTextRequiresNoConfirmation() {
        #expect(!QrPayloadKind.plainText.requiresCreateConfirmation)
    }

    @Test func nonPlainTextRequiresConfirmation() {
        #expect(QrPayloadKind.phone(number: "+1").requiresCreateConfirmation)
    }
}
