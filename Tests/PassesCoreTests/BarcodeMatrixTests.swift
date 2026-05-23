import Foundation
import Testing

@testable import PassesCore

@Suite("BarcodeMatrix")
struct BarcodeMatrixTests {

    @Test func isSetReadsModules() {
        let m = BarcodeMatrix(width: 2, height: 2, modules: [true, false, false, true])
        #expect(m.isSet(x: 0, y: 0))
        #expect(!m.isSet(x: 1, y: 0))
        #expect(!m.isSet(x: 0, y: 1))
        #expect(m.isSet(x: 1, y: 1))
    }

    @Test func equalityIsStructural() {
        let a = BarcodeMatrix(width: 2, height: 1, modules: [true, false])
        let b = BarcodeMatrix(width: 2, height: 1, modules: [true, false])
        let c = BarcodeMatrix(width: 2, height: 1, modules: [false, true])
        #expect(a == b)
        #expect(a != c)
    }

    @Test func descriptionDoesNotLeakModules() {
        // Pure data: description only exposes shape, not bits — matches Android's toString().
        let m = BarcodeMatrix(width: 3, height: 2, modules: [true, false, true, false, true, false])
        #expect(m.description == "BarcodeMatrix(width=3, height=2)")
    }
}
