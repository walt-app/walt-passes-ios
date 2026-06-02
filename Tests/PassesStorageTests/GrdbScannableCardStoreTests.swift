import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// Behavioral coverage for the scannable-card lane of `GrdbPassRepository` (ios-b1f.4) — the
/// storage behind the "Create a code" feature. Covers: create persists trimmed/normalized
/// values and returns the row id, the validator rejection bubbles up as
/// `.scannableCardRejected` with the typed reason (row never reaches disk), load/observe
/// reconstruct cards via the validator, the stream re-emits, delete is irreversible, and —
/// the headline acceptance — a created card survives a reopen of the database.
@Suite("GrdbScannableCardStore")
struct GrdbScannableCardStoreTests {

    private func makeRepository(
        at url: URL? = nil,
        now: @escaping @Sendable () -> Int64 = { 1_000 }
    ) throws -> GrdbPassRepository {
        let path = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_cards_\(UUID().uuidString).db")
        return try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: path), clock: now)
    }

    @Test func createPersistsAndAppearsInStream() async throws {
        let repo = try makeRepository()
        var iterator = repo.observeScannableCards().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)

        let input = ScannableCardCreateInput(payload: "  loyalty-123  ", format: .code128, label: "  Cafe  ")
        guard case .success(let id) = await repo.createScannableCard(input: input) else {
            Issue.record("create failed"); return
        }
        #expect(id.value == 1)

        let emitted = await iterator.next()
        #expect(emitted?.count == 1)
        // Trimmed values are persisted, not the raw padded input.
        #expect(emitted?.first?.payload == "loyalty-123")
        #expect(emitted?.first?.label == "Cafe")
        #expect(emitted?.first?.format == .code128)
        // The consumer-visible id is the stringified row id.
        #expect(emitted?.first?.id == ScannableCardId("1"))
    }

    @Test func loadReturnsCreatedCard() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.createScannableCard(
            input: ScannableCardCreateInput(payload: "https://x.example", format: .qr, label: "Site")
        ) else { Issue.record("create failed"); return }
        guard case .success(let card) = await repo.loadScannableCard(id: id) else {
            Issue.record("load failed"); return
        }
        #expect(card.payload == "https://x.example")
        #expect(card.format == .qr)
    }

    @Test func emptyLabelRejectedBeforeDisk() async throws {
        let repo = try makeRepository()
        let result = await repo.createScannableCard(
            input: ScannableCardCreateInput(payload: "1234", format: .qr, label: "   ")
        )
        #expect(result == .failure(error: .scannableCardRejected(reason: .invalidLabel(reason: .empty))))
        #expect(await repo.observeScannableCardsFirstSnapshot().isEmpty)
    }

    @Test func wrongLengthPayloadRejectedWithTypedReason() async throws {
        let repo = try makeRepository()
        // EAN-13 requires exactly 13 digits; 5 digits is a wrongLength rejection.
        let result = await repo.createScannableCard(
            input: ScannableCardCreateInput(payload: "12345", format: .ean13, label: "Card")
        )
        guard case .failure(.scannableCardRejected(.invalidPayload(let reason))) = result else {
            Issue.record("expected invalidPayload rejection, got \(result)"); return
        }
        guard case .wrongLength(let actual, let required, let format) = reason else {
            Issue.record("expected wrongLength, got \(reason)"); return
        }
        #expect(actual == 5)
        #expect(required == 13)
        #expect(format == .ean13)
    }

    @Test func deleteRemovesCardAndAbsentIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.createScannableCard(
            input: ScannableCardCreateInput(payload: "abc", format: .code128, label: "L")
        ) else { Issue.record("create failed"); return }
        guard case .success = await repo.deleteScannableCard(id: id) else {
            Issue.record("delete failed"); return
        }
        #expect(await repo.observeScannableCardsFirstSnapshot().isEmpty)

        guard case .failure(let error) = await repo.deleteScannableCard(id: id) else {
            Issue.record("expected failure"); return
        }
        #expect(error == .integrityViolation(recordId: .scannableCard(id)))
    }

    /// The headline acceptance for the epic: a created code survives an app relaunch.
    @Test func cardSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_cards_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try makeRepository(at: url, now: { 42 })
        _ = await first.createScannableCard(
            input: ScannableCardCreateInput(payload: "persist-me", format: .code128, label: "Keep")
        )
        first.close()

        let second = try makeRepository(at: url, now: { 42 })
        let cards = await second.observeScannableCardsFirstSnapshot()
        #expect(cards.map(\.payload) == ["persist-me"])
        #expect(cards.first?.createdAt == PassInstant(epochMillis: 42))
    }
}

extension GrdbPassRepository {
    /// Test helper: the first (current) snapshot from the scannable-card stream.
    fileprivate func observeScannableCardsFirstSnapshot() async -> [ScannableCard] {
        var iterator = observeScannableCards().makeAsyncIterator()
        return await iterator.next() ?? []
    }
}
