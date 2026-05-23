import Foundation
import PassesCore
import Testing

@testable import PassesStorage

/// Placeholder smoke test for the storage protocol surface.
@Suite("PassesStorage")
struct PassesStorageTests {

    private actor InMemoryStorage: PassStorage {
        private var passes: [String: Pass] = [:]
        func save(_ pass: Pass) async throws { passes[pass.id] = pass }
        func load(id: String) async throws -> Pass? { passes[id] }
        func all() async throws -> [Pass] { Array(passes.values) }
        func delete(id: String) async throws { passes.removeValue(forKey: id) }
    }

    @Test func roundTripSaveAndLoad() async throws {
        let storage = InMemoryStorage()
        let pass = Pass(id: "p1", label: "Test", issuer: nil, expiresAt: nil)
        try await storage.save(pass)
        let loaded = try await storage.load(id: "p1")
        #expect(loaded == pass)
    }
}
