import Foundation

/// PKPASS archive member names that the parser-glue layer, the manifest verifier, and the
/// hardened ZIP extractor must agree on byte-for-byte. The trust claim ("a manifest cannot
/// self-reference, and the signature signs the manifest") rides on three call sites using the
/// same string; the constant lives here so agreement is structural rather than three private
/// duplicates that could drift.
internal let signatureFileName = "signature"

/// See `signatureFileName` - same rationale, applied to `manifest.json`.
internal let manifestFileName = "manifest.json"

/// See `signatureFileName` - applied to `pass.json`.
internal let passJsonFileName = "pass.json"
