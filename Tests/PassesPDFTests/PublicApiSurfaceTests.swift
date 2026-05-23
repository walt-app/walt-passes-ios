import Foundation
import Testing
import PassesPDFCore

@testable import PassesPDF

/// Compile-time surface lock for ``PDFRendererBinder`` and ``PDFImporter``.
/// Mirrors Android's `PublicApiSurfaceTest`. Swift does not expose
/// declared-method reflection in a way that matches Kotlin's
/// `KClass.declaredMethods`, so the lock here is structural: code that
/// references each method by its full signature fails to compile if the
/// signature changes. Adding a `getText` / `getMetadata` / `extract` helper
/// to ``PDFRendererBinder`` would either break the existence test (helper
/// missing from the conformance) or pass review unchallenged — the deliberate
/// absence of such helpers is documented on the protocol itself.
///
/// The structural test is the closest Swift analogue to the
/// reflection-allowlist Android uses. A contributor adding a third public
/// requirement to ``PDFRendererBinder`` must update this file in the same
/// PR, mirroring the test-and-interface-in-lockstep discipline.
@Suite("PublicApiSurface")
struct PublicApiSurfaceTests {

    @Test func binderHasExactlyProbeAndRender() {
        // Compile-time witness: each existential is bound only if the type
        // declares the exact suspend signature. If a future contributor
        // changes the signature (renaming, reordering, adding a parameter
        // without a default), this stops compiling.
        let probe: (any PDFRendererBinder) -> (Data) async -> ProbeResult = { binder in
            { data in await binder.probe(pdf: data) }
        }
        let render: (any PDFRendererBinder) -> (Data, Int, Int, Int, RenderSourceRect) async -> RenderResult = { binder in
            { data, page, w, h, rect in
                await binder.render(pdf: data, page: page, widthPx: w, heightPx: h, sourceRect: rect)
            }
        }
        _ = probe
        _ = render
    }

    @Test func importerSurfaceHasOnlyImport() {
        // Compile-time witness for the importer's single method.
        let importer: (any PDFImporter)
            -> (PDFImportSource, String, @Sendable (String, Data, Int, Data) async throws -> Void) async throws -> PDFImportResult = { i in
                { source, label, persist in
                    try await i.import(source: source, displayLabel: label, persist: persist)
                }
            }
        _ = importer
    }

    @Test func documentRejectedKindEnumCoverage() {
        // Pin the exhaustive arm set. Adding an arm forces a touch here in
        // the same way Android's `RejectedKindWireSurfaceTest` enforces
        // coverage on its wire table.
        for kind in DocumentRejectedKind.allCases {
            switch kind {
            case .oversizedAtImport,
                 .notAPdf,
                 .encrypted,
                 .tooManyPages,
                 .rendererFailed,
                 .unsupportedAndroidVersion,
                 .encoderFailed,
                 .storageHandoffFailed:
                continue
            }
        }
        #expect(DocumentRejectedKind.allCases.count == 8)
    }
}
