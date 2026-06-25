import PassesPDFCore
import Testing

@testable import PassesPDFUI

/// Pure-Swift lock on the LRU access-order eviction contract for the
/// rasterised-page cache feeding `DocumentView`. Mirror of Android's
/// `RenderedPageCacheTest`. Substitutes `String` so the contract is
/// exercisable without involving CoreGraphics.
@Suite("RenderedPageCache")
struct RenderedPageCacheTests {

    private let docId = PDFDocumentId("doc-1")

    @Test func atCapacityNoEvictionFires() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        cache.put(documentId: docId, page: 0, value: "a")
        cache.put(documentId: docId, page: 1, value: "b")
        cache.put(documentId: docId, page: 2, value: "c")
        #expect(evicted.isEmpty)
        #expect(cache.size == 3)
    }

    @Test func pastCapacityEvictsLeastRecentlyInserted() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        cache.put(documentId: docId, page: 0, value: "a")
        cache.put(documentId: docId, page: 1, value: "b")
        cache.put(documentId: docId, page: 2, value: "c")
        cache.put(documentId: docId, page: 3, value: "d")
        #expect(evicted == ["a"])
        #expect(cache.get(documentId: docId, page: 0) == nil)
        #expect(cache.get(documentId: docId, page: 3) == "d")
        #expect(cache.size == 3)
    }

    @Test func getUpdatesAccessOrder() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        cache.put(documentId: docId, page: 0, value: "a")
        cache.put(documentId: docId, page: 1, value: "b")
        cache.put(documentId: docId, page: 2, value: "c")
        // Touch "a" so it becomes most-recently-used; "b" is now eldest.
        #expect(cache.get(documentId: docId, page: 0) == "a")
        cache.put(documentId: docId, page: 3, value: "d")
        #expect(evicted == ["b"])
        #expect(cache.get(documentId: docId, page: 1) == nil)
        #expect(cache.get(documentId: docId, page: 0) == "a")
    }

    @Test func replacingValueForSameKeyEvictsThePreviousValue() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        cache.put(documentId: docId, page: 0, value: "first")
        cache.put(documentId: docId, page: 0, value: "second")
        #expect(evicted == ["first"])
        #expect(cache.get(documentId: docId, page: 0) == "second")
        #expect(cache.size == 1)
    }

    @Test func multiplePagesPastWindowEvictsInAccessOrder() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        // Walk a 6-page document at the same render budget; eviction
        // order must match the user's pager swipes — oldest-by-access
        // falls out first.
        for (page, value) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            cache.put(documentId: docId, page: page, value: value)
        }
        #expect(evicted == ["a", "b", "c"])
        #expect(cache.size == 3)
    }

    @Test func keysAreScopedByDocumentId() {
        let a = PDFDocumentId("doc-a")
        let b = PDFDocumentId("doc-b")
        let cache = RenderedPageCache<String>(maxSize: 4)
        cache.put(documentId: a, page: 0, value: "a0")
        cache.put(documentId: b, page: 0, value: "b0")
        #expect(cache.get(documentId: a, page: 0) == "a0")
        #expect(cache.get(documentId: b, page: 0) == "b0")
    }

    @Test func clearEvictsEveryRetainedValue() {
        var evicted: [String] = []
        let cache = RenderedPageCache<String>(maxSize: 3) { evicted.append($0) }
        cache.put(documentId: docId, page: 0, value: "a")
        cache.put(documentId: docId, page: 1, value: "b")
        cache.put(documentId: docId, page: 2, value: "c")
        cache.clear()
        #expect(evicted == ["a", "b", "c"])
        #expect(cache.size == 0)
    }
}
