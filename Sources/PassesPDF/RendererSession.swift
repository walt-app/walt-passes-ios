import Foundation

/// Owns the connect / disconnect pair for a single renderer session. The
/// importer obtains a ``RendererSession`` for the duration of one import,
/// uses ``client`` for `probe` and `render`, and closes the session in a
/// `defer` — which guarantees the close runs whether the import succeeded,
/// was rejected at any step, or threw.
///
/// Mirrors Android's `RendererSession` seam. On Android the production
/// session calls `bindService` / `unbindService` against the isolated
/// renderer; on iOS the production session is a thin holder around a
/// ``PDFKitRenderer``, since PDFKit is same-process and has no
/// bind/unbind. Keeping the seam preserves the Android-shaped orchestration
/// in ``DefaultPDFImporter`` and lets unit tests inject recording sessions
/// that pin the "close runs on every outcome" invariant.
package protocol RendererSession: Sendable {
    var client: PDFRendererBinder { get }
    func close()
}

package protocol RendererSessionFactory: Sendable {
    func connect() async -> RendererSession
}

package struct DefaultRendererSession: RendererSession {
    package let client: PDFRendererBinder
    package init(client: PDFRendererBinder) {
        self.client = client
    }
    package func close() {}
}

package struct PDFKitRendererSessionFactory: RendererSessionFactory {
    package init() {}
    package func connect() async -> RendererSession {
        DefaultRendererSession(client: PDFKitRenderer())
    }
}
