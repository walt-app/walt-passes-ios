import Foundation

/// Minimal `Pass` value type — the public domain shape consumed by Walt.
///
/// Carries the parsed metadata fields a UI surface needs to render a pass
/// (label, masked PAN, network) without exposing raw PDF bytes. Full schema
/// parity with `passes-android`'s `Pass` lands with the Passes feature epic.
public struct Pass: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let issuer: String?
    public let expiresAt: Date?

    public init(id: String, label: String, issuer: String? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.label = label
        self.issuer = issuer
        self.expiresAt = expiresAt
    }
}
