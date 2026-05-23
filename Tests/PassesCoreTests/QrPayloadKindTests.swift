import Foundation
import Testing

@testable import PassesCore

@Suite("QrPayloadKind")
struct QrPayloadKindTests {

    @Test func armsAreReachableViaSwitch() {
        let kind: QrPayloadKind = .url(scheme: "https", host: "example.com", raw: "https://example.com")
        let branch: String
        switch kind {
        case .plainText: branch = "plainText"
        case .url: branch = "url"
        case .phone: branch = "phone"
        case .sms: branch = "sms"
        case .mailto: branch = "mailto"
        case .geo: branch = "geo"
        case .wifi: branch = "wifi"
        case .bitcoin: branch = "bitcoin"
        case .ethereum: branch = "ethereum"
        case .magnet: branch = "magnet"
        case .market: branch = "market"
        case .intent: branch = "intent"
        case .unknownScheme: branch = "unknownScheme"
        }
        #expect(branch == "url")
    }

    @Test func equalityRequiresAllAssociatedValues() {
        #expect(
            QrPayloadKind.url(scheme: "https", host: "a", raw: "https://a")
                == QrPayloadKind.url(scheme: "https", host: "a", raw: "https://a")
        )
        #expect(
            QrPayloadKind.url(scheme: "https", host: "a", raw: "https://a")
                != QrPayloadKind.url(scheme: "https", host: "b", raw: "https://a")
        )
        #expect(QrPayloadKind.plainText == QrPayloadKind.plainText)
        #expect(QrPayloadKind.magnet == QrPayloadKind.magnet)
    }

    @Test func wifiDoesNotCarryPassword() {
        // Drift detector: if a future change adds a password field to the wifi arm, the
        // associated-value count changes and this constructor call breaks compilation.
        let kind: QrPayloadKind = .wifi(ssid: "home")
        if case let .wifi(ssid) = kind {
            #expect(ssid == "home")
        } else {
            Issue.record("expected .wifi arm")
        }
    }
}
