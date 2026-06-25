import Foundation
import GRDB
import PassesCore
import Testing

@testable import PassesStorage

/// Behavioral coverage for the passes lane of `GrdbPassRepository` (ios-b1f.2): upsert
/// round-trips through images + locales, identity-tuple replacement preserves `created_at`
/// and the row id, summaries sort newest-first, the snapshot stream re-emits on mutation,
/// delete is irreversible and surfaces `.integrityViolation` for an absent row, and
/// post-`close` calls return `.databaseLocked`.
@Suite("GrdbPassRepository")
struct GrdbPassRepositoryTests {

    /// A mutable, thread-safe clock so tests can advance time between calls without tripping
    /// Swift 6's `@Sendable` capture check (a bare captured `var` is rejected).
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        func set(_ value: Int64) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
        var now: @Sendable () -> Int64 {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
    }

    private func makeRepository(now: @escaping @Sendable () -> Int64 = { 1_000 }) throws -> GrdbPassRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_passes_repo_\(UUID().uuidString).db")
        let queue = try GrdbDatabaseFactory.open(at: url)
        return try GrdbPassRepository(dbQueue: queue, clock: now)
    }

    private func samplePass(
        serial: String = "SN-1",
        org: String = "Org",
        type: PassType = .generic
    ) -> Pass {
        Pass(
            type: type,
            serialNumber: serial,
            description: "Desc",
            organizationName: org,
            expirationDate: PassInstant(epochMillis: 999),
            voided: false,
            colors: PassColors(foreground: ColorValue(rgb: 0x00FF00)),
            frontFields: PassFields(primary: [PassField(key: "k", label: "L", value: "V")]),
            backFields: [],
            barcode: Barcode(format: .qr, message: "hello", messageEncoding: "iso-8859-1"),
            images: [.icon: ImageBytes(bytes: Data([1, 2, 3]))],
            locales: [PassLocale("en"): LocalizedStrings(entries: ["k": "Key"])]
        )
    }

    @Test func upsertThenLoadRoundTripsImagesAndLocales() async throws {
        let repo = try makeRepository()
        let pass = samplePass()
        guard case .success(let id) = await repo.upsert(pass: pass, signatureStatus: .selfSigned) else {
            Issue.record("upsert failed")
            return
        }
        guard case .success(let stored) = await repo.load(id: id) else {
            Issue.record("load failed")
            return
        }
        #expect(stored.pass.serialNumber == "SN-1")
        #expect(stored.pass.barcode?.message == "hello")
        #expect(stored.pass.colors.foreground == ColorValue(rgb: 0x00FF00))
        #expect(stored.pass.images[.icon]?.bytes == Data([1, 2, 3]))
        #expect(stored.pass.locales[PassLocale("en")]?.entries["k"] == "Key")
        #expect(stored.signatureStatus == .selfSigned)
        #expect(stored.createdAt == PassInstant(epochMillis: 1_000))
    }

    @Test func upsertReplacesByIdentityPreservingIdAndCreatedAt() async throws {
        let clock = TestClock(1_000)
        let repo = try makeRepository(now: clock.now)

        guard case .success(let firstId) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("first upsert failed")
            return
        }
        clock.set(5_000)
        let updated = samplePass()  // same identity tuple (type/serial/org)
        guard case .success(let secondId) = await repo.upsert(pass: updated, signatureStatus: .appleVerified) else {
            Issue.record("second upsert failed")
            return
        }
        #expect(firstId == secondId)  // replaced, not inserted

        let all = await repo.passes
        #expect(all.count == 1)
        #expect(all.first?.createdAt == PassInstant(epochMillis: 1_000))  // preserved
        #expect(all.first?.updatedAt == PassInstant(epochMillis: 5_000))  // bumped
        #expect(all.first?.signatureStatus == .appleVerified)
    }

    @Test func passesSortNewestFirst() async throws {
        let clock = TestClock(0)
        let repo = try makeRepository(now: clock.now)
        clock.set(100)
        _ = await repo.upsert(pass: samplePass(serial: "A"), signatureStatus: .unsigned)
        clock.set(200)
        _ = await repo.upsert(pass: samplePass(serial: "B"), signatureStatus: .unsigned)
        let serials = await repo.passes.map(\.serialNumber)
        #expect(serials == ["B", "A"])
    }

    @Test func streamReEmitsOnUpsert() async throws {
        let repo = try makeRepository()
        var iterator = repo.passesStream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.isEmpty == true)
        _ = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned)
        let afterInsert = await iterator.next()
        #expect(afterInsert?.count == 1)
    }

    @Test func deleteRemovesRowAndAbsentIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("upsert failed")
            return
        }
        guard case .success = await repo.delete(id: id) else {
            Issue.record("delete failed")
            return
        }
        #expect(await repo.passes.isEmpty)

        guard case .failure(let error) = await repo.delete(id: id) else {
            Issue.record("expected failure on second delete")
            return
        }
        #expect(error == .integrityViolation(recordId: .pass(id)))
    }

    @Test func updatePassUserLabelSetsTrimmedLabel() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("upsert failed")
            return
        }
        guard case .success = await repo.updatePassUserLabel(id: id, label: "  Gym card  ") else {
            Issue.record("update failed")
            return
        }
        guard case .success(let summary) = await repo.summaryOf(id: id) else {
            Issue.record("summaryOf failed")
            return
        }
        #expect(summary.userLabel == "Gym card")
    }

    @Test func updatePassUserLabelClearsOnNilOrBlank() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("upsert failed")
            return
        }
        _ = await repo.updatePassUserLabel(id: id, label: "Temp")
        // nil clears.
        _ = await repo.updatePassUserLabel(id: id, label: nil)
        guard case .success(let afterNil) = await repo.summaryOf(id: id) else {
            Issue.record("summaryOf failed")
            return
        }
        #expect(afterNil.userLabel == nil)
        // blank-after-trim also clears.
        _ = await repo.updatePassUserLabel(id: id, label: "Temp")
        _ = await repo.updatePassUserLabel(id: id, label: "   ")
        guard case .success(let afterBlank) = await repo.summaryOf(id: id) else {
            Issue.record("summaryOf failed")
            return
        }
        #expect(afterBlank.userLabel == nil)
    }

    @Test func updatePassUserLabelAtCapAcceptedOverCapRejected() async throws {
        let repo = try makeRepository()
        guard case .success(let id) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("upsert failed")
            return
        }
        let atCap = String(repeating: "a", count: PassUserLabelBounds.maxUserLabelChars)
        guard case .success = await repo.updatePassUserLabel(id: id, label: atCap) else {
            Issue.record("at-cap label should be accepted")
            return
        }
        let overCap = String(repeating: "a", count: PassUserLabelBounds.maxUserLabelChars + 1)
        guard case .failure(let error) = await repo.updatePassUserLabel(id: id, label: overCap) else {
            Issue.record("expected over-cap rejection")
            return
        }
        #expect(error == .passRejected(kind: .labelTooLong))
        // The rejected update must not have overwritten the accepted at-cap value.
        guard case .success(let summary) = await repo.summaryOf(id: id) else {
            Issue.record("summaryOf failed")
            return
        }
        #expect(summary.userLabel == atCap)
    }

    @Test func updatePassUserLabelCapRejectionPrecedesUnknownId() async throws {
        let repo = try makeRepository()
        let overCap = String(repeating: "a", count: PassUserLabelBounds.maxUserLabelChars + 1)
        // Too-long label on a nonexistent id surfaces as passRejected, not integrityViolation.
        guard case .failure(let error) = await repo.updatePassUserLabel(id: PassRecordId(404), label: overCap) else {
            Issue.record("expected cap rejection")
            return
        }
        #expect(error == .passRejected(kind: .labelTooLong))
    }

    @Test func updatePassUserLabelUnknownIdIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        guard case .failure(let error) = await repo.updatePassUserLabel(id: PassRecordId(404), label: "x") else {
            Issue.record("expected integrity violation")
            return
        }
        #expect(error == .integrityViolation(recordId: .pass(PassRecordId(404))))
    }

    @Test func updatePassUserLabelDoesNotBumpUpdatedAt() async throws {
        let clock = TestClock(1_000)
        let repo = try makeRepository(now: clock.now)
        guard case .success(let id) = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned) else {
            Issue.record("upsert failed")
            return
        }
        clock.set(9_000)
        _ = await repo.updatePassUserLabel(id: id, label: "Renamed")
        guard case .success(let summary) = await repo.summaryOf(id: id) else {
            Issue.record("summaryOf failed")
            return
        }
        #expect(summary.userLabel == "Renamed")
        #expect(summary.updatedAt.epochMillis == 1_000)
    }

    @Test func loadAbsentPassIsIntegrityViolation() async throws {
        let repo = try makeRepository()
        let result = await repo.load(id: PassRecordId(404))
        #expect(result == .failure(error: .integrityViolation(recordId: .pass(PassRecordId(404)))))
    }

    @Test func callsAfterCloseReturnDatabaseLocked() async throws {
        let repo = try makeRepository()
        repo.close()
        repo.close()  // idempotent
        let result = await repo.upsert(pass: samplePass(), signatureStatus: .unsigned)
        #expect(result == .failure(error: .databaseLocked))
    }

    @Test func snapshotSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walt_passes_persist_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 7 })
        _ = await first.upsert(pass: samplePass(serial: "persist"), signatureStatus: .unsigned)
        first.close()

        // A fresh repository over the same file sees the persisted row at construction.
        let second = try GrdbPassRepository(dbQueue: try GrdbDatabaseFactory.open(at: url), clock: { 7 })
        #expect(await second.passes.map(\.serialNumber) == ["persist"])
    }
}
