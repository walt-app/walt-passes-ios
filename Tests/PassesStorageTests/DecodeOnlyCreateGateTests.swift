import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// Storage-level twins of the decode-only validator gate (ios-pjs.15): a PDF417/Aztec
/// input must be refused as `.unsupportedFormat` on both write paths and never reach disk
/// — without the gate the row persists and renders as a failure tile forever.
@Suite("Decode-only create gate")
struct DecodeOnlyCreateGateTests {

    private func makeRepository() throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_decode_only_gate_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        return try GrdbPassRepository(dbQueue: queue, clock: { 1_000 })
    }

    @Test func createRefusesADecodeOnlyFormat() async throws {
        let repository = try makeRepository()
        let result = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: "M1SYNTHETIC/BCBP", format: .aztec, label: "Flight")
        )
        guard case .failure(.scannableCardRejected(.unsupportedFormat(let format))) = result else {
            Issue.record("aztec create should be unsupportedFormat, got \(result)")
            return
        }
        #expect(format == .aztec)
    }

    @Test func updateRefusesADecodeOnlyFormatAndLeavesTheRow() async throws {
        let repository = try makeRepository()
        let created = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: "WALT-0042", format: .qr, label: "Card")
        )
        guard case .success(let id) = created else {
            Issue.record("setup create failed: \(created)")
            return
        }
        let update = await repository.updateScannableCard(
            id: id,
            input: ScannableCardCreateInput(payload: "PAYLOAD", format: .pdf417, label: "Card")
        )
        guard case .failure(.scannableCardRejected(.unsupportedFormat)) = update else {
            Issue.record("pdf417 update should be unsupportedFormat, got \(update)")
            return
        }
        let loaded = await repository.loadScannableCard(id: id)
        guard case .success(let card) = loaded else {
            Issue.record("card should survive the rejected update, got \(loaded)")
            return
        }
        #expect(card.format == .qr)
        #expect(card.payload == "WALT-0042")
    }
}
