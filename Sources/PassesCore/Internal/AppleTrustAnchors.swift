import Foundation
import X509

/// Loads the Apple trust anchors and known WWDR intermediates bundled under `Resources/certs/`
/// (mirrors Android's `passes-core/resources/.../certs`). Loaded once on first access and cached.
/// The provenance of every certificate is documented in `Resources/certs/SECURITY-CERTS.md`.
///
/// **Why bundled, not platform-trusted.** The system trust store is mutable and device-specific.
/// Walt's trust claim is "this pass chains to Apple," not "this pass chains to whatever this
/// device happens to trust today." Bundling pins the trust set and lets the parser surface
/// `certChainIncomplete` for a chain the OS might trust but that does not reach an Apple root.
///
/// **Why no network fetches.** Chasing an issuer URL embedded in the signature would let a
/// signature blob influence which issuers we contact; `certChainIncomplete` is the fallback.
internal enum AppleTrustAnchors {
    static let bundledTrustAnchorFilenames = [
        "apple-root-ca",
        "apple-root-ca-g2",
        "apple-root-ca-g3",
    ]

    static let bundledIntermediateFilenames = [
        "apple-wwdr-g3",
        "apple-wwdr-g6",
    ]

    private struct BundledCerts {
        let anchors: [Certificate]
        let intermediates: [Certificate]
    }

    private static let cache: Result<BundledCerts, Error> = Result { try loadFromResources() }

    /// The Apple roots. Used as the `trustRoots` `CertificateStore` for chain validation.
    static func trustAnchors() throws -> [Certificate] {
        try cache.get().anchors
    }

    /// Bundled WWDR intermediates. Added to `additionalIntermediateCertificates` so a signature
    /// blob that omits its intermediate can still chain to a bundled root; never trust anchors
    /// on their own.
    static func knownIntermediates() throws -> [Certificate] {
        try cache.get().intermediates
    }

    private static func loadFromResources() throws -> BundledCerts {
        let anchors = try bundledTrustAnchorFilenames.map { try loadResource($0) }
        let intermediates = try bundledIntermediateFilenames.map { try loadResource($0) }
        return BundledCerts(anchors: anchors, intermediates: intermediates)
    }

    private static func loadResource(_ filename: String) throws -> Certificate {
        guard let url = Bundle.module.url(forResource: filename, withExtension: "cer", subdirectory: "certs") else {
            throw TrustAnchorError.missingResource(filename)
        }
        let der = try Data(contentsOf: url)
        return try Certificate(derEncoded: [UInt8](der))
    }

    enum TrustAnchorError: Error {
        case missingResource(String)
    }
}
