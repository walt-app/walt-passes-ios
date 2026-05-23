import Foundation
import PassesCore

/// PDF-import surface for the passes pipeline.
///
/// Production implementation uses `PDFKit` with hard limits on page count,
/// image dimensions, and decode time (see PDF_THREAT_MODEL.md). The Passes
/// feature epic implements it; this file is a placeholder for the repo
/// standup (ios-382.10).
public protocol PDFImporter: Sendable {
    func importPDF(at url: URL) async throws -> Pass
}
