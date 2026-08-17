import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// Storage-level behavior for the now-creatable 2D pair (ios-pjs.16): a Latin-1 payload
/// persists; a non-Latin-1 payload is refused as `wrongCharset` (the Latin-1 posture, ADR
/// `barcode-decode-1`) and never reaches disk.
@Suite("Aztec/PDF417 create path")
struct AztecPdf417CreatePathTests {

    private func makeRepository() throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_2d_create_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        return try GrdbPassRepository(dbQueue: queue, clock: { 1_000 })
    }

    @Test func latin1PayloadPersistsAndLoadsBack() async throws {
        let repository = try makeRepository()
        for format: ScannableFormat in [.pdf417, .aztec] {
            let created = await repository.createScannableCard(
                input: ScannableCardCreateInput(
                    payload: "M1DOE/JANE MS EABC123", format: format, label: "Flight")
            )
            guard case .success(let id) = created else {
                Issue.record("\(format) create should persist, got \(created)")
                continue
            }
            let loaded = await repository.loadScannableCard(id: id)
            guard case .success(let card) = loaded else {
                Issue.record("\(format) card should load back, got \(loaded)")
                continue
            }
            #expect(card.format == format)
            #expect(card.payload == "M1DOE/JANE MS EABC123")
        }
    }

    @Test func nonLatin1PayloadIsRefusedAsWrongCharset() async throws {
        let repository = try makeRepository()
        let result = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: "東京メトロ", format: .aztec, label: "Card")
        )
        guard
            case .failure(.scannableCardRejected(.invalidPayload(.wrongCharset))) = result
        else {
            Issue.record("CJK aztec create should be wrongCharset, got \(result)")
            return
        }
    }
}

/// The read-side charset twin: rehydration runs the validator, so a raw row whose payload
/// the Latin-1 posture no longer admits is dropped from the list rather than surfacing as
/// a card that would render a mojibake-scanning symbol.
@Suite("Aztec/PDF417 hydration gate")
struct AztecPdf417HydrationGateTests {
    @Test func rawNonLatin1RowIsDroppedOnRead() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_2d_read_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO scannable_cards (payload, format, label, created_at_epoch_ms) "
                    + "VALUES (?, ?, ?, ?)",
                arguments: ["東京メトロ", "aztec", "Card", 1_000]
            )
        }
        let cards = try await queue.read { try GrdbScannableCardStore.listAll($0) }
        #expect(cards.isEmpty, "a non-Latin-1 2D row must be dropped on read")
    }

    @Test func latin1RowHydrates() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_2d_read_ok_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO scannable_cards (payload, format, label, created_at_epoch_ms) "
                    + "VALUES (?, ?, ?, ?)",
                arguments: ["M1SYNTHETIC/BCBP", "pdf417", "Flight", 1_000]
            )
        }
        let cards = try await queue.read { try GrdbScannableCardStore.listAll($0) }
        #expect(cards.count == 1)
        #expect(cards.first?.format == .pdf417)
    }
}
