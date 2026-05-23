import Foundation
import PassesPDFCore

/// Bounded access-ordered LRU keyed by `(PDFDocumentId, page)` for the
/// rasterised pages displayed by `DocumentView`. Generic over the value type
/// so the eviction-order contract is testable without involving CoreGraphics.
///
/// Mirror of Android's `is.walt.passes.pdf.ui.internal.RenderedPageCache`.
/// Thread-safety: callers invoke this from the SwiftUI main actor (the same
/// scope that drives `Task { ... }` inside views); no internal synchronisation
/// is added. A future background prefetch path would wrap this rather than
/// mutating it from off-main.
final class RenderedPageCache<V> {
    private struct Key: Hashable {
        let documentId: PDFDocumentId
        let page: Int
    }

    private let maxSize: Int
    private let onEvict: (V) -> Void
    /// Access-ordered storage: keys at the start of `order` are
    /// least-recently-used. The dictionary holds the values.
    private var order: [Key] = []
    private var storage: [Key: V] = [:]

    init(maxSize: Int, onEvict: @escaping (V) -> Void = { _ in }) {
        precondition(maxSize > 0, "maxSize must be positive (was \(maxSize))")
        self.maxSize = maxSize
        self.onEvict = onEvict
    }

    var size: Int { storage.count }

    /// Read-or-miss. A hit moves the key to most-recently-used.
    func get(documentId: PDFDocumentId, page: Int) -> V? {
        let key = Key(documentId: documentId, page: page)
        guard let value = storage[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        return value
    }

    /// Insert or replace. Replacing an existing key evicts the previous value
    /// through `onEvict`; insertion past `maxSize` evicts the LRU entry.
    func put(documentId: PDFDocumentId, page: Int, value: V) {
        let key = Key(documentId: documentId, page: page)
        if let prior = storage.removeValue(forKey: key) {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            onEvict(prior)
        }
        storage[key] = value
        order.append(key)
        while order.count > maxSize {
            let eldest = order.removeFirst()
            if let evicted = storage.removeValue(forKey: eldest) {
                onEvict(evicted)
            }
        }
    }

    /// Drop every cached entry, firing `onEvict` for each. Hosts call this
    /// when the view leaves the composition or the displayed document changes.
    func clear() {
        guard !storage.isEmpty else { return }
        let snapshot = order.compactMap { storage[$0] }
        storage.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        for value in snapshot {
            onEvict(value)
        }
    }
}
