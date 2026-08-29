import Foundation

/// Real Apple-signed pkpass manifest + detached CMS, loaded from bundled test resources.
struct AppleSignedFixture {
    /// Both issuers ship bare `rsaEncryption`; they differ in how the SHA-256 digest identifier
    /// encodes its parameters. Raw values are the resource subdirectories.
    enum Issuer: String {
        /// Tixly Chroniques: parameters absent, as Apple PassKit emits.
        case tixly = "Fixtures/apple-signed"
        /// Tickster: explicit NULL at both the SignedData and SignerInfo levels.
        case tickster = "Fixtures/apple-signed-sha256-null"
    }

    let manifest: [UInt8]
    let signature: [UInt8]

    static func load(_ issuer: Issuer = .tixly) throws -> AppleSignedFixture {
        AppleSignedFixture(
            manifest: try bytes(resource: "manifest", ext: "json", issuer: issuer),
            signature: try bytes(resource: "signature", ext: nil, issuer: issuer)
        )
    }

    private static func bytes(resource: String, ext: String?, issuer: Issuer) throws -> [UInt8] {
        guard
            let url = Bundle.module.url(
                forResource: resource,
                withExtension: ext,
                subdirectory: issuer.rawValue
            )
        else {
            throw FixtureError.missing("\(resource).\(ext ?? "")")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    enum FixtureError: Error { case missing(String) }
}
