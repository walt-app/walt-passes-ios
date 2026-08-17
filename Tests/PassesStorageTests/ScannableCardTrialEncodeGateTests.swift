import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// The trial-encode gate on both scannable-card write paths (wpass-1kg analogue,
/// ios-pjs.19). A payload the validator admits but no encoder can render must be
/// rejected as `.encoderFailure` before the row reaches disk — without the gate it
/// persists and first surfaces as a blank barcode with no reason attached.
@Suite("Scannable-card trial-encode gate")
struct ScannableCardTrialEncodeGateTests {

    /// 800 CJK characters clear the validator's 2000-char QR cap but weigh 2400 UTF-8
    /// bytes — past the v40-M byte-mode ceiling. The wpass-1kg gap payload.
    private let densePayload = String(repeating: "東", count: 800)

    private func makeRepository() throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_scannable_gate_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        return try GrdbPassRepository(dbQueue: queue, clock: { 1_000 })
    }

    @Test func createRejectsAValidatorCleanPayloadNoEncoderCanRender() async throws {
        let repository = try makeRepository()
        let result = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: densePayload, format: .qr, label: "Dense")
        )
        guard
            case .failure(.scannableCardRejected(.encoderFailure(.payloadTooDense))) = result
        else {
            Issue.record("dense QR create should be encoderFailure(payloadTooDense), got \(result)")
            return
        }
    }

    @Test func updateRejectionLeavesTheExistingRowRenderable() async throws {
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
            input: ScannableCardCreateInput(payload: densePayload, format: .qr, label: "Card")
        )
        guard case .failure(.scannableCardRejected(.encoderFailure(.payloadTooDense))) = update
        else {
            Issue.record("dense QR update should be encoderFailure(payloadTooDense), got \(update)")
            return
        }

        // The rejected edit must not have touched the row — the card still renders.
        let loaded = await repository.loadScannableCard(id: id)
        guard case .success(let card) = loaded else {
            Issue.record("card should survive a rejected update, got \(loaded)")
            return
        }
        #expect(card.payload == "WALT-0042")
    }

    @Test func validatorRejectionStillWinsOverTheEncoder() async throws {
        // Non-ASCII Code128 fails both the validator's charset rule and the encoder;
        // the gate runs validate-then-encode, so the validator's arm must surface.
        let repository = try makeRepository()
        let result = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: "café", format: .code128, label: "Card")
        )
        guard case .failure(.scannableCardRejected(.invalidPayload(.wrongCharset))) = result else {
            Issue.record("charset rejection should keep the validator's arm, got \(result)")
            return
        }
    }

    @Test func fullLengthQrPayloadStillPersists() async throws {
        // Full-length happy path through the gate: the validator's 2000-char QR cap
        // keeps an all-alphanumeric payload under the byte-mode ceiling, so no gate
        // arm can fire here. (The encoder's own over-rejection guard — an alphanumeric
        // payload past the ceiling — lives in BarcodeEncoderTests; the validator cap
        // makes it unreachable through this repository.)
        let repository = try makeRepository()
        let payload = String(repeating: "WALT7 ", count: 333) + "AB"
        let result = await repository.createScannableCard(
            input: ScannableCardCreateInput(payload: payload, format: .qr, label: "Long card")
        )
        guard case .success = result else {
            Issue.record("full-length QR payload should persist, got \(result)")
            return
        }
    }
}
