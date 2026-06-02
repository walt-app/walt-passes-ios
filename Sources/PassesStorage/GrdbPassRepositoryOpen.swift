import Foundation

extension GrdbPassRepository {
    /// The public entry point a consumer (walt-app's `DataPasses`) uses to stand up the
    /// repository: opens (creating if absent) the Data-Protected GRDB database at `url`,
    /// migrates it to the current schema, and constructs the repository — all behind a
    /// typed `StorageResult` so a key/disk/downgrade failure degrades to `.unavailable`
    /// at the composition root rather than throwing.
    ///
    /// `GrdbDatabaseFactory` and its `DatabaseOpenError` are `internal`; this is the one
    /// public seam, so callers cannot accidentally open a database without the migration
    /// and Data Protection steps. Mirrors the factory role of Android's
    /// `PassesModule.buildPassesRuntime` repository factory.
    public static func open(
        at url: URL,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> StorageResult<GrdbPassRepository> {
        do {
            let queue = try GrdbDatabaseFactory.open(at: url)
            let repository = try GrdbPassRepository(dbQueue: queue, clock: clock)
            return .success(value: repository)
        } catch {
            return .failure(error: StorageErrorMapper.map(error))
        }
    }
}
