import Foundation
import SQLite3

// sqlite3_bind_* 以 SQLITE_STATIC(nil)绑定时,SQLite 不会拷贝缓冲区,而是在 step 时才读取;
// Swift 桥接的临时 NSString/Data 缓冲区可能在 step 前被释放,必须用 SQLITE_TRANSIENT 让 SQLite 拷贝。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Prepared statements for hot, fixed-shape queries. All access is guarded by `lock`;
    /// entries are reset + cleared before each reuse and finalized in deinit.
    private var preparedStatements: [String: OpaquePointer] = [:]
    /// Insertion order of the keys in `preparedStatements`. Used to evict the
    /// oldest entry once the cache is at capacity. Call sites with optional
    /// filters build SQL by string concatenation, so shapes are bounded but not
    /// a single constant; without an eviction policy a long-lived process would
    /// retain one handle per shape forever.
    private var preparedStatementOrder: [String] = []
    /// Upper bound on cached statements. Comfortably covers every SQL shape the
    /// current call sites can produce while keeping handles/memory bounded.
    private static let maxCachedStatements = 32
    /// Bumped on every mutation of `daily_rollups`; keys the yearly rollup memo below.
    private var rollupsRevision = 0
    private var yearlyRollupsCache: (year: Int, revision: Int, rollups: [DailyRollup])?
    public let path: String

    /// Identifies one `daily_rollups` row while a bulk insert accumulates its delta.
    private struct RollupKey: Hashable {
        let dayKey: String
        let sourceId: String
    }

    /// Accumulated `daily_rollups` delta for one `RollupKey`.
    private struct RollupDelta {
        var totalTokens: Int64 = 0
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheTokens: Int64 = 0
        var costUSD: Double = 0
    }

    /// Column list of `unified_token_records` that `insertRecords` writes; the
    /// order must match `bindRecord`.
    private static let insertColumnList = "(id, source_id, timestamp, timestamp_source, day_key, session_key, project_folder, model, provider, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, cost_usd)"
    private static let insertColumnCount: Int32 = 15
    /// Rows per multi-row INSERT: 15 columns × 50 rows = 750 bound parameters,
    /// far below SQLite's parameter limit, and a batch needs only a handful of
    /// statement shapes.
    private static let insertChunkRows = 50
    /// Primary-key probe used to learn which of a batch's records are new.
    private static let recordExistsSQL = "SELECT 1 FROM unified_token_records WHERE id = ?;"
    /// Full existing row used only by explicitly correction-capable adapters.
    private static let existingRecordSQL = """
    SELECT source_id, timestamp, timestamp_source, day_key, session_key, project_folder, model, provider,
           input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, cost_usd
    FROM unified_token_records WHERE id = ?;
    """
    /// Parameter numbers deliberately match `bindRecord`, allowing correction
    /// rows to reuse the same binding helper and column ordering as inserts.
    private static let updateRecordSQL = """
    UPDATE unified_token_records SET
        source_id = ?2, timestamp = ?3, timestamp_source = ?4, day_key = ?5, session_key = ?6,
        project_folder = ?7, model = ?8, provider = ?9,
        input_tokens = ?10, output_tokens = ?11, cache_read_tokens = ?12,
        cache_write_tokens = ?13, total_tokens = ?14, cost_usd = ?15
    WHERE id = ?1;
    """
    /// Constant-shape upserts routed through `cachedStatement` instead of
    /// prepare/finalize on every `insertRecords` call.
    private static let rollupUpsertSQL = """
    INSERT INTO daily_rollups (day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day_key, source_id) DO UPDATE SET
        total_tokens = total_tokens + excluded.total_tokens,
        input_tokens = input_tokens + excluded.input_tokens,
        output_tokens = output_tokens + excluded.output_tokens,
        cache_tokens = cache_tokens + excluded.cache_tokens,
        cost_usd = cost_usd + excluded.cost_usd;
    """
    private static let cursorUpsertSQL = """
    INSERT INTO sync_cursors (source_id, cursor_payload, last_synced_at)
    VALUES (?, ?, ?)
    ON CONFLICT(source_id) DO UPDATE SET
        cursor_payload = excluded.cursor_payload,
        last_synced_at = excluded.last_synced_at;
    """
    /// Memoized chunk SQL by row count. A batch reuses the same one or two
    /// shapes for every chunk, so the string is joined once per shape instead of
    /// once per chunk. Only touched while `lock` is held.
    private var insertStatementSQL: [String: String] = [:]

    private func insertRecordsSQL(rowCount: Int, ignoreConflicts: Bool = true) -> String {
        let memoKey = "\(rowCount)-\(ignoreConflicts)"
        if let memoized = insertStatementSQL[memoKey] { return memoized }
        let boundRow = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        let values = Array(repeating: boundRow, count: rowCount).joined(separator: ", ")
        let conflictClause = ignoreConflicts ? "OR IGNORE " : ""
        let sql = "INSERT \(conflictClause)INTO unified_token_records \(Self.insertColumnList) VALUES \(values);"
        insertStatementSQL[memoKey] = sql
        return sql
    }

    private static func bindRecord(_ stmt: OpaquePointer, baseParameter: Int32, _ r: UnifiedTokenRecord) {
        sqlite3_bind_text(stmt, baseParameter + 1, (r.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, baseParameter + 2, (r.sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, baseParameter + 3, Int64(r.timestamp.timeIntervalSince1970 * 1000))
        sqlite3_bind_text(stmt, baseParameter + 4, (r.timestampSource.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, baseParameter + 5, (r.dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, baseParameter + 6, (r.sessionKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let pf = r.projectFolder {
            sqlite3_bind_text(stmt, baseParameter + 7, (pf as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, baseParameter + 7)
        }
        sqlite3_bind_text(stmt, baseParameter + 8, (r.model as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let prov = r.provider {
            sqlite3_bind_text(stmt, baseParameter + 9, (prov as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, baseParameter + 9)
        }
        sqlite3_bind_int(stmt, baseParameter + 10, Int32(r.inputTokens))
        sqlite3_bind_int(stmt, baseParameter + 11, Int32(r.outputTokens))
        sqlite3_bind_int(stmt, baseParameter + 12, Int32(r.cacheReadTokens))
        sqlite3_bind_int(stmt, baseParameter + 13, Int32(r.cacheWriteTokens))
        sqlite3_bind_int(stmt, baseParameter + 14, Int32(r.totalTokens))
        sqlite3_bind_double(stmt, baseParameter + 15, r.rawCostUSD ?? 0.0)
    }

    /// Reclaims the write-ahead log before the process goes away.
    ///
    /// A status-item app is normally quit through `NSApp.terminate`, which exits
    /// without running `sqlite3_close`, so nothing checkpoints on the way out.
    public func checkpointAndTruncate() {
        lock.lock(); defer { lock.unlock() }
        try? execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public init(path: String) throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &dbPointer, flags, nil) != SQLITE_OK {
            let errMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw NSError(domain: "DatabaseManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        self.db = dbPointer
        self.path = path
        try configureDatabase()
        try createTables()
    }

    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    deinit {
        for stmt in preparedStatements.values {
            sqlite3_finalize(stmt)
        }
        preparedStatements.removeAll()
        preparedStatementOrder.removeAll()
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA busy_timeout = 3000;")
        // Query-time tuning (U-20). Defaults are cache_size=-2000 (~2 MB),
        // mmap_size=0, temp_store=FILE; those make range scans re-read pages and
        // spill GROUP BY / ORDER BY B-trees to disk on every refresh.
        try execute(sql: "PRAGMA cache_size = -16000;")      // ~16 MB page cache
        try execute(sql: "PRAGMA mmap_size = 268435456;")    // 256 MB memory-mapped I/O
        try execute(sql: "PRAGMA temp_store = MEMORY;")      // keep temp B-trees in RAM
        try execute(sql: "PRAGMA wal_autocheckpoint = 1000;")
        // Cap what a checkpoint leaves behind. Without this, SQLite reuses the WAL
        // file at its high-water mark instead of shrinking it, so one large ingest
        // (or a process killed before it could checkpoint) leaves a many-hundred-MB
        // WAL for every later launch to re-scan.
        try execute(sql: "PRAGMA journal_size_limit = 16777216;") // 16 MB
        // Cheap SQLite-recommended housekeeping; records optimal-index stats for
        // statements executed on this connection. Never blocks.
        try execute(sql: "PRAGMA optimize;")
        // Non-blocking passive checkpoint: reclaims/truncates a WAL left behind by
        // a previous process that was killed before it could checkpoint. `PASSIVE`
        // (unlike `TRUNCATE`) never blocks and is safe on the open path; on a
        // non-WAL database (e.g. `:memory:`) it is a no-op.
        try execute(sql: "PRAGMA wal_checkpoint(PASSIVE);")
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS unified_token_records (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            timestamp_source TEXT NOT NULL DEFAULT 'event',
            day_key TEXT NOT NULL,
            session_key TEXT NOT NULL,
            project_folder TEXT,
            model TEXT NOT NULL,
            provider TEXT,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            cost_usd REAL NOT NULL DEFAULT 0.0
        );
        CREATE INDEX IF NOT EXISTS idx_records_day_source ON unified_token_records(day_key, source_id);
        CREATE INDEX IF NOT EXISTS idx_records_source ON unified_token_records(source_id COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_records_timestamp ON unified_token_records(timestamp);
        CREATE INDEX IF NOT EXISTS idx_records_project ON unified_token_records(project_folder);
        CREATE INDEX IF NOT EXISTS idx_records_model ON unified_token_records(model);
        -- Covering indexes (U-05). The GROUP BY column leads so the index can be
        -- scanned in group order, and the aggregate inputs (`total_tokens`,
        -- `cost_usd`) plus the filtered `timestamp` are covered, so
        -- fetchModelDistribution(sinceTimestamp:) / fetchProjectRankings(sinceTimestamp:)
        -- avoid a full table scan + per-row table lookup. Project rankings still
        -- materialize every grouped folder spelling because canonical merging then
        -- happens in Swift before the bounded public result is selected. (A
        -- timestamp-leading variant was tried first and was rejected by the
        -- planner: model distribution's ORDER BY on the aggregate still needs a
        -- TEMP B-TREE either way, so there was no reason to give up the already
        -- ordered single-column index.) Idempotent: existing databases pick these
        -- up on the next open.
        CREATE INDEX IF NOT EXISTS idx_records_model_covering ON unified_token_records(model, total_tokens, cost_usd, timestamp);
        CREATE INDEX IF NOT EXISTS idx_records_project_covering ON unified_token_records(project_folder, total_tokens, cost_usd, timestamp);

        CREATE TABLE IF NOT EXISTS sync_cursors (
            source_id TEXT PRIMARY KEY,
            cursor_payload BLOB NOT NULL,
            last_synced_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS daily_rollups (
            day_key TEXT NOT NULL,
            source_id TEXT NOT NULL,
            total_tokens INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_tokens INTEGER NOT NULL,
            cost_usd REAL NOT NULL,
            PRIMARY KEY (day_key, source_id)
        );
        """
        try execute(sql: sql)
        try migrateTimestampSourceIfNeeded()

        // Self-heal: clean up legacy records where DSH source used "dsh" as model name or emitted duplicate projcache deltas
        var dshCorruptCheck: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM unified_token_records WHERE source_id = 'dsh' AND (model = 'dsh' OR id LIKE 'dsh_%_cum_%') LIMIT 1;", -1, &dshCorruptCheck, nil) == SQLITE_OK {
            if sqlite3_step(dshCorruptCheck) == SQLITE_ROW {
                sqlite3_finalize(dshCorruptCheck)
                dshCorruptCheck = nil
                try? resetRecords(for: "dsh")
            } else {
                sqlite3_finalize(dshCorruptCheck)
            }
        }
    }

    private func migrateTimestampSourceIfNeeded() throws {
        let sql = "PRAGMA table_info(unified_token_records);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to inspect unified_token_records schema: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(statement) }
        var hasTimestampSource = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1),
               String(cString: name) == "timestamp_source" {
                hasTimestampSource = true
                break
            }
        }
        if !hasTimestampSource {
            try execute(sql: "ALTER TABLE unified_token_records ADD COLUMN timestamp_source TEXT NOT NULL DEFAULT 'event';")
        }
    }

    private func execute(sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.flatMap { String(cString: $0) } ?? "Unknown SQL error"
            sqlite3_free(errMsg)
            throw NSError(domain: "DatabaseManager", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
    private func lastErrorMessage() -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "Unknown database error"
    }

    private func cachedStatement(sql: String, errorCode: Int, description: String) throws -> OpaquePointer {
        if let existing = preparedStatements[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return existing
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw NSError(domain: "DatabaseManager", code: errorCode, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare \(description): \(lastErrorMessage())"])
        }
        // Bounded cache: evict the oldest shape before inserting a new one. All
        // call sites run while holding `lock`, so no evicted statement is ever in
        // flight across calls.
        if preparedStatements.count >= Self.maxCachedStatements, let oldest = preparedStatementOrder.first {
            preparedStatementOrder.removeFirst()
            if let evicted = preparedStatements.removeValue(forKey: oldest) {
                sqlite3_finalize(evicted)
            }
        }
        preparedStatements[sql] = prepared
        preparedStatementOrder.append(sql)
        return prepared
    }

    private static func rollupDelta(
        for record: UnifiedTokenRecord,
        multiplier: Int64 = 1
    ) -> RollupDelta {
        RollupDelta(
            totalTokens: Int64(record.totalTokens) * multiplier,
            inputTokens: Int64(record.inputTokens) * multiplier,
            outputTokens: Int64(record.outputTokens) * multiplier,
            cacheTokens: Int64(record.cacheReadTokens + record.cacheWriteTokens) * multiplier,
            costUSD: (record.rawCostUSD ?? 0.0) * Double(multiplier)
        )
    }

    private static func record(from stmt: OpaquePointer) -> UnifiedTokenRecord {
        let timestampMillis = sqlite3_column_int64(stmt, 1)
        return UnifiedTokenRecord(
            id: "",
            sourceId: String(cString: sqlite3_column_text(stmt, 0)),
            timestamp: Date(timeIntervalSince1970: Double(timestampMillis) / 1000.0),
            timestampSource: Self.timestampSource(from: stmt, column: 2),
            dayKey: String(cString: sqlite3_column_text(stmt, 3)),
            sessionKey: String(cString: sqlite3_column_text(stmt, 4)),
            projectFolder: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5)),
            model: String(cString: sqlite3_column_text(stmt, 6)),
            provider: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 7)),
            inputTokens: Int(sqlite3_column_int(stmt, 8)),
            outputTokens: Int(sqlite3_column_int(stmt, 9)),
            cacheReadTokens: Int(sqlite3_column_int(stmt, 10)),
            cacheWriteTokens: Int(sqlite3_column_int(stmt, 11)),
            rawCostUSD: sqlite3_column_double(stmt, 13)
        )
    }

    private static func timestampSource(from stmt: OpaquePointer, column: Int32) -> TimestampSource {
        guard let value = sqlite3_column_text(stmt, column) else { return .event }
        return TimestampSource(rawValue: String(cString: value)) ?? .unknown
    }

    private static func recordsHaveSameStorageValues(
        _ lhs: UnifiedTokenRecord,
        _ rhs: UnifiedTokenRecord
    ) -> Bool {
        Int64(lhs.timestamp.timeIntervalSince1970 * 1000) == Int64(rhs.timestamp.timeIntervalSince1970 * 1000)
            && lhs.sourceId == rhs.sourceId
            && lhs.timestampSource == rhs.timestampSource
            && lhs.dayKey == rhs.dayKey
            && lhs.sessionKey == rhs.sessionKey
            && lhs.projectFolder == rhs.projectFolder
            && lhs.model == rhs.model
            && lhs.provider == rhs.provider
            && lhs.inputTokens == rhs.inputTokens
            && lhs.outputTokens == rhs.outputTokens
            && lhs.cacheReadTokens == rhs.cacheReadTokens
            && lhs.cacheWriteTokens == rhs.cacheWriteTokens
            && (lhs.rawCostUSD ?? 0.0) == (rhs.rawCostUSD ?? 0.0)
    }

    /// Inserts records and returns the number that actually changed. By
    /// default, existing IDs use the efficient `INSERT OR IGNORE` behavior.
    /// When `updateExisting` is true, a different existing row is corrected and
    /// its old values are subtracted from `daily_rollups` before the new values
    /// are added. Equal repeats remain no-ops.
    @discardableResult
    public func insertRecords(
        _ records: [UnifiedTokenRecord],
        updateCursorFor sourceId: String? = nil,
        cursor: SyncCursor? = nil,
        updateExisting: Bool = false
    ) throws -> Int {
        guard !records.isEmpty || cursor != nil else { return 0 }
        // Codec + clock work happens before the global lock: the critical
        // section below should only cover SQLite stepping.
        let encodedCursor: Data? = if sourceId != nil, let cursor {
            try JSONEncoder().encode(cursor)
        } else {
            nil
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock(); defer { lock.unlock() }

        var changedCount = 0
        var rollupsChanged = false
        try execute(sql: "BEGIN TRANSACTION;")
        do {
            if !records.isEmpty {
                // Rollup deltas are accumulated per (day_key, source_id) and
                // flushed as one upsert per key afterwards. A cold sync inserts
                // tens of thousands of records that collapse to a few hundred
                // (day, source) pairs, so upserting per record executed tens of
                // thousands of redundant statement steps.
                var rollupDeltas: [RollupKey: RollupDelta] = [:]
                var seenIds = Set<String>()
                seenIds.reserveCapacity(records.count)
                var index = 0
                while index < records.count {
                    let chunkCount = min(Self.insertChunkRows, records.count - index)

                    // Probe first so duplicate batches do no writes and rollup
                    // deltas cover exactly the rows that changed.
                    let probe = try cachedStatement(
                        sql: updateExisting ? Self.existingRecordSQL : Self.recordExistsSQL,
                        errorCode: 3,
                        description: updateExisting ? "existing record statement" : "record existence statement"
                    )
                    var freshRecords: [UnifiedTokenRecord] = []
                    freshRecords.reserveCapacity(chunkCount)
                    for offset in 0..<chunkCount {
                        let record = records[index + offset]
                        guard seenIds.insert(record.id).inserted else { continue }
                        sqlite3_bind_text(probe, 1, (record.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        let step = sqlite3_step(probe)
                        if step == SQLITE_DONE {
                            freshRecords.append(record)
                        } else if step == SQLITE_ROW {
                            guard updateExisting else {
                                sqlite3_reset(probe)
                                continue
                            }
                            let existing = Self.record(from: probe)
                            sqlite3_reset(probe)
                            guard !Self.recordsHaveSameStorageValues(existing, record) else { continue }

                            let update = try cachedStatement(
                                sql: Self.updateRecordSQL,
                                errorCode: 7,
                                description: "record update statement"
                            )
                            Self.bindRecord(update, baseParameter: 0, record)
                            guard sqlite3_step(update) == SQLITE_DONE,
                                  sqlite3_changes(db) == 1 else {
                                throw NSError(domain: "DatabaseManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to update record '\(record.id)': \(lastErrorMessage())"])
                            }
                            changedCount += 1

                            // A metadata-only correction does not affect a rollup.
                            // Otherwise subtract from the old (day, source) and add
                            // to the new one, including when either key changed.
                            let rollupValuesChanged = existing.totalTokens != record.totalTokens
                                || existing.inputTokens != record.inputTokens
                                || existing.outputTokens != record.outputTokens
                                || existing.cacheReadTokens != record.cacheReadTokens
                                || existing.cacheWriteTokens != record.cacheWriteTokens
                                || (existing.rawCostUSD ?? 0.0) != (record.rawCostUSD ?? 0.0)
                            if rollupValuesChanged {
                                rollupsChanged = true
                                let oldKey = RollupKey(dayKey: existing.dayKey, sourceId: existing.sourceId)
                                var oldDelta = rollupDeltas[oldKey] ?? RollupDelta()
                                let subtraction = Self.rollupDelta(for: existing, multiplier: -1)
                                oldDelta.totalTokens += subtraction.totalTokens
                                oldDelta.inputTokens += subtraction.inputTokens
                                oldDelta.outputTokens += subtraction.outputTokens
                                oldDelta.cacheTokens += subtraction.cacheTokens
                                oldDelta.costUSD += subtraction.costUSD
                                rollupDeltas[oldKey] = oldDelta

                                let newKey = RollupKey(dayKey: record.dayKey, sourceId: record.sourceId)
                                var newDelta = rollupDeltas[newKey] ?? RollupDelta()
                                let addition = Self.rollupDelta(for: record)
                                newDelta.totalTokens += addition.totalTokens
                                newDelta.inputTokens += addition.inputTokens
                                newDelta.outputTokens += addition.outputTokens
                                newDelta.cacheTokens += addition.cacheTokens
                                newDelta.costUSD += addition.costUSD
                                rollupDeltas[newKey] = newDelta
                            }
                        } else {
                            sqlite3_reset(probe)
                            throw NSError(domain: "DatabaseManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to look up record '\(record.id)': \(lastErrorMessage())"])
                        }
                        sqlite3_reset(probe)
                    }

                    if !freshRecords.isEmpty {
                        // One multi-row statement per chunk instead of one
                        // statement step per record (~1.25x on a cold 46k-record
                        // sync). `freshRecords` holds only absent primary keys,
                        // so `OR IGNORE` has nothing left to drop and the
                        // accumulated deltas match the inserted rows exactly.
                        let stmt = try cachedStatement(
                            sql: insertRecordsSQL(rowCount: freshRecords.count),
                            errorCode: 3,
                            description: "record insert statement"
                        )
                        for (offset, record) in freshRecords.enumerated() {
                            Self.bindRecord(stmt, baseParameter: Int32(offset) * Self.insertColumnCount, record)
                        }
                        guard sqlite3_step(stmt) == SQLITE_DONE else {
                            throw NSError(domain: "DatabaseManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to insert records: \(lastErrorMessage())"])
                        }
                        changedCount += Int(sqlite3_changes(db))
                        rollupsChanged = true

                        for record in freshRecords {
                            let key = RollupKey(dayKey: record.dayKey, sourceId: record.sourceId)
                            let addition = Self.rollupDelta(for: record)
                            var delta = rollupDeltas[key] ?? RollupDelta()
                            delta.totalTokens += addition.totalTokens
                            delta.inputTokens += addition.inputTokens
                            delta.outputTokens += addition.outputTokens
                            delta.cacheTokens += addition.cacheTokens
                            delta.costUSD += addition.costUSD
                            rollupDeltas[key] = delta
                        }
                    }
                    index += chunkCount
                }

                if !rollupDeltas.isEmpty {
                    let rollupStmt = try cachedStatement(
                        sql: Self.rollupUpsertSQL,
                        errorCode: 4,
                        description: "rollup upsert statement"
                    )

                    for (key, delta) in rollupDeltas {
                        sqlite3_bind_text(rollupStmt, 1, (key.dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(rollupStmt, 2, (key.sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int64(rollupStmt, 3, delta.totalTokens)
                        sqlite3_bind_int64(rollupStmt, 4, delta.inputTokens)
                        sqlite3_bind_int64(rollupStmt, 5, delta.outputTokens)
                        sqlite3_bind_int64(rollupStmt, 6, delta.cacheTokens)
                        sqlite3_bind_double(rollupStmt, 7, delta.costUSD)

                        let rollupStep = sqlite3_step(rollupStmt)
                        guard rollupStep == SQLITE_DONE else {
                            throw NSError(domain: "DatabaseManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to upsert rollup for '\(key.dayKey)'/'\(key.sourceId)': \(lastErrorMessage())"])
                        }
                        sqlite3_reset(rollupStmt)
                    }
                }
            }

            if let sourceId = sourceId, let cursorData = encodedCursor {
                let cursorStmt = try cachedStatement(
                    sql: Self.cursorUpsertSQL,
                    errorCode: 5,
                    description: "cursor upsert statement"
                )

                sqlite3_bind_text(cursorStmt, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                _ = cursorData.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(cursorStmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(cursorStmt, 3, nowMillis)

                let cursorStep = sqlite3_step(cursorStmt)
                guard cursorStep == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to step cursor statement: \(lastErrorMessage())"])
                }
            }

            try execute(sql: "COMMIT;")
            // Equal duplicates and metadata-only corrections do not invalidate
            // the memoized aggregate. `changedCount` separately controls the
            // coordinator's change notification.
            if rollupsChanged { rollupsRevision += 1 }
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
        return changedCount
    }

    /// Atomically replaces every record, rollup, and cursor belonging to one
    /// adapter. Any insert, rollup, or cursor failure rolls the whole cutover
    /// back, leaving the previously stored source state intact.
    @discardableResult
    public func replaceSourceRecords(
        _ records: [UnifiedTokenRecord],
        sourceId: String,
        cursor: SyncCursor
    ) throws -> Int {
        guard records.allSatisfy({ $0.sourceId == sourceId }) else {
            throw NSError(
                domain: "DatabaseManager",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "Replacement records must belong to source '\(sourceId)'"]
            )
        }

        let cursorData = try JSONEncoder().encode(cursor)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock(); defer { lock.unlock() }

        try execute(sql: "BEGIN TRANSACTION;")
        do {
            try executeBound("DELETE FROM unified_token_records WHERE source_id = ?;", values: [.text(sourceId)])
            try executeBound("DELETE FROM daily_rollups WHERE source_id = ?;", values: [.text(sourceId)])

            var rollupDeltas: [RollupKey: RollupDelta] = [:]
            var index = 0
            while index < records.count {
                let chunkCount = min(Self.insertChunkRows, records.count - index)
                let chunk = Array(records[index..<(index + chunkCount)])
                // Plain INSERT is intentional: after deleting this source, a
                // duplicate stable ID is a cutover collision and must fail
                // atomically rather than silently produce incomplete data.
                let stmt = try cachedStatement(
                    sql: insertRecordsSQL(rowCount: chunk.count, ignoreConflicts: false),
                    errorCode: 3,
                    description: "replacement record insert statement"
                )
                for (offset, record) in chunk.enumerated() {
                    Self.bindRecord(stmt, baseParameter: Int32(offset) * Self.insertColumnCount, record)
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw NSError(
                        domain: "DatabaseManager",
                        code: 36,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to replace records for '\(sourceId)': \(lastErrorMessage())"]
                    )
                }
                for record in chunk {
                    let key = RollupKey(dayKey: record.dayKey, sourceId: record.sourceId)
                    let addition = Self.rollupDelta(for: record)
                    var delta = rollupDeltas[key] ?? RollupDelta()
                    delta.totalTokens += addition.totalTokens
                    delta.inputTokens += addition.inputTokens
                    delta.outputTokens += addition.outputTokens
                    delta.cacheTokens += addition.cacheTokens
                    delta.costUSD += addition.costUSD
                    rollupDeltas[key] = delta
                }
                index += chunkCount
            }

            for (key, delta) in rollupDeltas {
                try upsertRollup(key: key, delta: delta)
            }

            let cursorStmt = try cachedStatement(
                sql: Self.cursorUpsertSQL,
                errorCode: 5,
                description: "cursor upsert statement"
            )
            sqlite3_bind_text(cursorStmt, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = cursorData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(cursorStmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(cursorStmt, 3, nowMillis)
            guard sqlite3_step(cursorStmt) == SQLITE_DONE else {
                throw NSError(
                    domain: "DatabaseManager",
                    code: 36,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to replace cursor for '\(sourceId)': \(lastErrorMessage())"]
                )
            }

            try execute(sql: "COMMIT;")
            rollupsRevision += 1
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
        return records.count
    }

    private enum BoundSQLValue {
        case text(String)
    }

    private func executeBound(_ sql: String, values: [BoundSQLValue]) throws {
        let stmt = try cachedStatement(sql: sql, errorCode: 36, description: "replacement statement")
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            if case .text(let value) = value {
                sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseManager", code: 36, userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
        }
    }

    private func upsertRollup(key: RollupKey, delta: RollupDelta) throws {
        let stmt = try cachedStatement(
            sql: Self.rollupUpsertSQL,
            errorCode: 4,
            description: "rollup upsert statement"
        )
        sqlite3_bind_text(stmt, 1, (key.dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (key.sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, delta.totalTokens)
        sqlite3_bind_int64(stmt, 4, delta.inputTokens)
        sqlite3_bind_int64(stmt, 5, delta.outputTokens)
        sqlite3_bind_int64(stmt, 6, delta.cacheTokens)
        sqlite3_bind_double(stmt, 7, delta.costUSD)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseManager",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "Failed to replace rollup for '\(key.dayKey)'/'\(key.sourceId)': \(lastErrorMessage())"]
            )
        }
    }

    public func fetchDailyRollups(forYear year: Int) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        if let cached = yearlyRollupsCache, cached.year == year, cached.revision == rollupsRevision {
            return cached.rollups
        }
        // `day_key` is a fixed `yyyy-MM-dd` string (see `UnifiedTokenRecord`), so a
        // half-open range is equivalent to the old `LIKE '<year>-%'` prefix match
        // but can use the primary-key index instead of scanning the table (U-06).
        let start = "\(year)-01-01"
        let next = "\(year + 1)-01-01"
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key >= ? AND day_key < ? ORDER BY day_key ASC;"
        let stmt = try cachedStatement(sql: sql, errorCode: 9, description: "daily rollups fetch statement")

        sqlite3_bind_text(stmt, 1, (start as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (next as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var result: [DailyRollup] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let dayKey = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let totalTokens = Int(sqlite3_column_int64(stmt, 2))
                let inputTokens = Int(sqlite3_column_int64(stmt, 3))
                let outputTokens = Int(sqlite3_column_int64(stmt, 4))
                let cacheTokens = Int(sqlite3_column_int64(stmt, 5))
                let costUSD = sqlite3_column_double(stmt, 6)
                result.append(DailyRollup(
                    dayKey: dayKey,
                    sourceId: sourceId,
                    totalTokens: totalTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheTokens,
                    costUSD: costUSD
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch daily rollups: \(lastErrorMessage())"])
            }
        }
        yearlyRollupsCache = (year: year, revision: rollupsRevision, rollups: result)
        return result
    }

    public func fetchDailyRollups(dayKey: String) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key = ? ORDER BY source_id ASC;"
        let stmt = try cachedStatement(sql: sql, errorCode: 9, description: "daily rollups day fetch statement")

        sqlite3_bind_text(stmt, 1, (dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var result: [DailyRollup] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let dayKey = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let totalTokens = Int(sqlite3_column_int64(stmt, 2))
                let inputTokens = Int(sqlite3_column_int64(stmt, 3))
                let outputTokens = Int(sqlite3_column_int64(stmt, 4))
                let cacheTokens = Int(sqlite3_column_int64(stmt, 5))
                let costUSD = sqlite3_column_double(stmt, 6)
                result.append(DailyRollup(
                    dayKey: dayKey,
                    sourceId: sourceId,
                    totalTokens: totalTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheTokens,
                    costUSD: costUSD
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch daily rollups for day: \(lastErrorMessage())"])
            }
        }
        return result
    }

    public func fetchDailyRollups(startDate: String, endDate: String) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key >= ? AND day_key <= ? ORDER BY day_key ASC;"
        let stmt = try cachedStatement(sql: sql, errorCode: 9, description: "daily rollups range fetch statement")

        sqlite3_bind_text(stmt, 1, (startDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (endDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var result: [DailyRollup] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let dayKey = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let totalTokens = Int(sqlite3_column_int64(stmt, 2))
                let inputTokens = Int(sqlite3_column_int64(stmt, 3))
                let outputTokens = Int(sqlite3_column_int64(stmt, 4))
                let cacheTokens = Int(sqlite3_column_int64(stmt, 5))
                let costUSD = sqlite3_column_double(stmt, 6)
                result.append(DailyRollup(
                    dayKey: dayKey,
                    sourceId: sourceId,
                    totalTokens: totalTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheTokens,
                    costUSD: costUSD
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch daily rollups range: \(lastErrorMessage())"])
            }
        }
        return result
    }

    public func fetchRecords(sinceTimestamp: Int64) throws -> [UnifiedTokenRecord] {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        SELECT id, source_id, timestamp, timestamp_source, day_key, session_key, project_folder, model, provider,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, cost_usd
        FROM unified_token_records
        WHERE timestamp >= ?
        ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetchRecords statement: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }
        guard let stmt else { return [] }

        sqlite3_bind_int64(stmt, 1, sinceTimestamp)
        var result: [UnifiedTokenRecord] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let timestamp = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000.0)
                let timestampSource = Self.timestampSource(from: stmt, column: 3)
                let dayKey = String(cString: sqlite3_column_text(stmt, 4))
                let sessionKey = String(cString: sqlite3_column_text(stmt, 5))
                let projectFolder: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
                let model = String(cString: sqlite3_column_text(stmt, 7))
                let provider: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
                let inputTokens = Int(sqlite3_column_int(stmt, 9))
                let outputTokens = Int(sqlite3_column_int(stmt, 10))
                let cacheReadTokens = Int(sqlite3_column_int(stmt, 11))
                let cacheWriteTokens = Int(sqlite3_column_int(stmt, 12))
                let rawCostUSD: Double? = sqlite3_column_type(stmt, 14) != SQLITE_NULL ? sqlite3_column_double(stmt, 14) : nil

                result.append(UnifiedTokenRecord(
                    id: id,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    timestampSource: timestampSource,
                    dayKey: dayKey,
                    sessionKey: sessionKey,
                    projectFolder: projectFolder,
                    model: model,
                    provider: provider,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    rawCostUSD: rawCostUSD
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch records: \(lastErrorMessage())"])
            }
        }
        return result
    }

    public func fetchAvailableYears() throws -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT DISTINCT substr(day_key, 1, 4) AS yr FROM daily_rollups ORDER BY yr DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 17, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare available years query: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }

        var years: [Int] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0) {
                    let str = String(cString: text)
                    if let y = Int(str) {
                        years.append(y)
                    }
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 18, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch available years: \(lastErrorMessage())"])
            }
        }
        return years
    }
    /// Canonical display key for a stored project folder. Historical rows
    /// contain forked shapes of the same directory: trailing slashes
    /// ("/a/b/") and Pi hyphen-decoding splits ("/a/trove/rag" for
    /// "/a/trove-rag" — the session-folder encoding turns every "/" into "-",
    /// so original hyphens are ambiguous). The trailing slash is trimmed,
    /// then components are re-joined greedily: at each step the longest
    /// hyphen-joined group that exists on disk wins. When nothing further
    /// matches, the stored path is kept as-is, so one directory counts once
    /// however it was recorded and unknown paths are never mangled.
    public static func canonicalProjectFolder(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") && trimmed.count > 1 {
            trimmed.removeLast()
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: trimmed) else { return trimmed }
        // Only hyphen-split candidates are worth re-joining: otherwise the
        // stored path is authoritative (e.g. a deleted directory).
        let tokens = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return trimmed }
        var resolved = ""
        var index = 0

        while index < tokens.count {
            var match: String?
            var next = tokens.count
            while next > index {
                let group = tokens[index..<next].joined(separator: "-")
                let candidate = resolved + "/" + group
                if fm.fileExists(atPath: candidate) {
                    match = candidate
                    break
                }
                next -= 1
            }
            guard let found = match else { return trimmed }
            resolved = found
            // Advance past the tokens consumed by the match. The matched
            // group re-joins (next - index) tokens with hyphens; recompute by
            // shrinking `next` from the top would lose the count, so re-derive:
            // the longest match wins, i.e. the first (largest next) that hit.
            index = next
        }
        return resolved.isEmpty ? trimmed : resolved
    }

    public func fetchProjectRankings(
        limit: Int = 10,
        sourceId: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        sinceTimestamp: Int64? = nil
    ) throws -> [(project: String, totalTokens: Int, costUSD: Double)] {
        lock.lock(); defer { lock.unlock() }

        let resultLimit = max(0, limit)
        guard resultLimit > 0 else { return [] }
        var whereClauses = ["project_folder IS NOT NULL", "project_folder != ''"]
        var binds: [Any] = []
        if let sourceId = sourceId, !sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whereClauses.append("source_id = ? COLLATE NOCASE")
            binds.append(sourceId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let start = startDate {
            whereClauses.append("day_key >= ?")
            binds.append(start)
        }
        if let end = endDate {
            whereClauses.append("day_key <= ?")
            binds.append(end)
        }
        if let since = sinceTimestamp {
            whereClauses.append("timestamp >= ?")
            binds.append(since)
        }

        let sql = """
        SELECT project_folder, SUM(total_tokens) AS sum_tokens, SUM(cost_usd) AS sum_cost
        FROM unified_token_records
        WHERE \(whereClauses.joined(separator: " AND "))
        GROUP BY project_folder;
        """
        let stmt = try cachedStatement(sql: sql, errorCode: 13, description: "project rankings statement")

        var bindIndex: Int32 = 1
        for value in binds {
            if let str = value as? String {
                sqlite3_bind_text(stmt, bindIndex, (str as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if let int64 = value as? Int64 {
                sqlite3_bind_int64(stmt, bindIndex, int64)
            }
            bindIndex += 1
        }
        var result: [(project: String, totalTokens: Int, costUSD: Double)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let project = String(cString: sqlite3_column_text(stmt, 0))
                let totalTokens = Int(sqlite3_column_int64(stmt, 1))
                let costUSD = sqlite3_column_double(stmt, 2)
                result.append((project: project, totalTokens: totalTokens, costUSD: costUSD))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch project rankings: \(lastErrorMessage())"])
            }
        }
        // Canonicalization happens in Swift and an unbounded number of stored
        // aliases may collapse to one project. Apply the bound only after all
        // grouped raw candidates are merged, otherwise raw aliases can crowd a
        // genuinely top-ranked canonical project out of the result.
        var merged: [String: (tokens: Int, cost: Double)] = [:]
        merged.reserveCapacity(result.count)
        for row in result {
            let key = Self.canonicalProjectFolder(row.project)
            if let existing = merged[key] {
                merged[key] = (existing.tokens + row.totalTokens, existing.cost + row.costUSD)
            } else {
                merged[key] = (row.totalTokens, row.costUSD)
            }
        }
        return merged.map { (project: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                return $0.project < $1.project
            }
            .prefix(resultLimit)
            .map { $0 }
    }

    public func fetchModelDistribution(
        limit: Int = 10,
        sourceId: String? = nil,
        sinceTimestamp: Int64? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> [(model: String, tokens: Int, costUSD: Double)] {
        lock.lock(); defer { lock.unlock() }

        var whereClauses: [String] = ["model IS NOT NULL", "model != ''"]
        var binds: [Any] = []

        if let sourceId = sourceId, !sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whereClauses.append("source_id = ? COLLATE NOCASE")
            binds.append(sourceId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let since = sinceTimestamp {
            whereClauses.append("timestamp >= ?")
            binds.append(since)
        }
        if let start = startDate {
            whereClauses.append("day_key >= ?")
            binds.append(start)
        }
        if let end = endDate {
            whereClauses.append("day_key <= ?")
            binds.append(end)
        }

        let whereString = whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT model, SUM(total_tokens) AS sum_tokens, SUM(cost_usd) AS sum_cost
        FROM unified_token_records
        WHERE \(whereString)
        GROUP BY model
        ORDER BY sum_tokens DESC
        LIMIT ?;
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 25, description: "model distribution statement")

        var bindIndex: Int32 = 1
        for val in binds {
            if let str = val as? String {
                sqlite3_bind_text(stmt, bindIndex, (str as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if let int64 = val as? Int64 {
                sqlite3_bind_int64(stmt, bindIndex, int64)
            }
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        var result: [(model: String, tokens: Int, costUSD: Double)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let model = String(cString: sqlite3_column_text(stmt, 0))
                let totalTokens = Int(sqlite3_column_int64(stmt, 1))
                let costUSD = sqlite3_column_double(stmt, 2)
                result.append((model: model, tokens: totalTokens, costUSD: costUSD))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 26, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch model distribution: \(lastErrorMessage())"])
            }
        }
        return result
    }


    public func fetchRecordStats(forSourceId sourceId: String) throws -> (count: Int, lastTimestamp: Date?) {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT COUNT(*), MAX(timestamp) FROM unified_token_records WHERE source_id = ? COLLATE NOCASE;"
        let stmt = try cachedStatement(sql: sql, errorCode: 15, description: "record stats statement")

        sqlite3_bind_text(stmt, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            let count = Int(sqlite3_column_int(stmt, 0))
            let lastTimestamp: Date?
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                let ms = sqlite3_column_int64(stmt, 1)
                lastTimestamp = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            } else {
                lastTimestamp = nil
            }
            return (count: count, lastTimestamp: lastTimestamp)
        } else if step == SQLITE_DONE {
            return (count: 0, lastTimestamp: nil)
        } else {
            throw NSError(domain: "DatabaseManager", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch record stats: \(lastErrorMessage())"])
        }
    }

    public func fetchCursor(for sourceId: String) throws -> SyncCursor? {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT cursor_payload FROM sync_cursors WHERE source_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare cursor fetch statement: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let bytes = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(bytes))
                return try? JSONDecoder().decode(SyncCursor.self, from: data)
            }
        } else if step != SQLITE_DONE {
            throw NSError(domain: "DatabaseManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch cursor: \(lastErrorMessage())"])
        }
        return nil
    }
    public func fetchTotalRecordCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT COUNT(*) FROM unified_token_records;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 19, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare total record count statement: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    public func fetchAllTimeTotals(sourceId: String? = nil) throws -> AllTimeTotals {
        lock.lock(); defer { lock.unlock() }

        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filterApplied = trimmedSource != nil && !trimmedSource!.isEmpty

        let sql: String
        if filterApplied {
            sql = """
            SELECT
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(cache_write_tokens), 0),
                COALESCE(SUM(cost_usd), 0.0)
            FROM unified_token_records
            WHERE source_id = ? COLLATE NOCASE;
            """
        } else {
            sql = """
            SELECT
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(cache_write_tokens), 0),
                COALESCE(SUM(cost_usd), 0.0)
            FROM unified_token_records;
            """
        }

        let stmt = try cachedStatement(sql: sql, errorCode: 20, description: "all time totals statement")

        if filterApplied, let source = trimmedSource {
            sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let totalTokens = Int(sqlite3_column_int64(stmt, 0))
            let inputTokens = Int(sqlite3_column_int64(stmt, 1))
            let outputTokens = Int(sqlite3_column_int64(stmt, 2))
            let cacheReadTokens = Int(sqlite3_column_int64(stmt, 3))
            let cacheWriteTokens = Int(sqlite3_column_int64(stmt, 4))
            let totalCostUSD = sqlite3_column_double(stmt, 5)
            return AllTimeTotals(
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                totalCostUSD: totalCostUSD
            )
        }

        return AllTimeTotals(
            totalTokens: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalCostUSD: 0.0
        )
    }

    public struct HourlyBucketTotals: Sendable, Equatable {
        public let hourIndex: Int
        public let totalTokens: Int
        public let totalCostUSD: Double

        public init(hourIndex: Int, totalTokens: Int, totalCostUSD: Double) {
            self.hourIndex = hourIndex
            self.totalTokens = totalTokens
            self.totalCostUSD = totalCostUSD
        }
    }

    /// Aggregates tokens and cost into hour-sized buckets keyed by
    /// `(timestamp - originTimestamp) / 3_600_000`, computed entirely in SQL so
    /// no raw rows are materialized in Swift. Callers discard indexes outside
    /// the range they care about.
    public func fetchHourlyBuckets(
        originTimestamp: Int64,
        sinceTimestamp: Int64,
        sourceId: String? = nil
    ) throws -> [HourlyBucketTotals] {
        lock.lock(); defer { lock.unlock() }

        var whereClauses: [String] = ["timestamp >= ?2"]
        var binds: [(index: Int32, value: Any)] = [(2, sinceTimestamp)]
        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = trimmedSource, !source.isEmpty {
            whereClauses.append("source_id = ?3 COLLATE NOCASE")
            binds.append((3, source))
        }

        let sql = """
        SELECT (timestamp - ?1) / 3600000 AS hour_index,
               COALESCE(SUM(total_tokens), 0),
               COALESCE(SUM(cost_usd), 0.0)
        FROM unified_token_records
        WHERE \(whereClauses.joined(separator: " AND "))
        GROUP BY hour_index;
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 27, description: "hourly buckets statement")
        sqlite3_bind_int64(stmt, 1, originTimestamp)
        for bind in binds {
            if let intVal = bind.value as? Int64 {
                sqlite3_bind_int64(stmt, bind.index, intVal)
            } else if let strVal = bind.value as? String {
                sqlite3_bind_text(stmt, bind.index, (strVal as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
        }

        var result: [HourlyBucketTotals] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let hourIndex = Int(sqlite3_column_int64(stmt, 0))
                let totalTokens = Int(sqlite3_column_int64(stmt, 1))
                let totalCostUSD = sqlite3_column_double(stmt, 2)
                result.append(HourlyBucketTotals(hourIndex: hourIndex, totalTokens: totalTokens, totalCostUSD: totalCostUSD))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 28, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch hourly buckets: \(lastErrorMessage())"])
            }
        }
        return result
    }
    /// Aggregates tokens per (hour bucket, model). The hour bucket is keyed by
    /// `(timestamp - originTimestamp) / 3_600_000` — identical semantics to
    /// `fetchHourlyBuckets`. Rows with NULL/empty models are excluded (same
    /// rule as `fetchModelDistribution`), as are zero-token groups so callers
    /// only ever see models that actually consumed tokens.
    public func fetchHourlyModelBuckets(
        originTimestamp: Int64,
        sinceTimestamp: Int64,
        sourceId: String? = nil
    ) throws -> [(hourIndex: Int, model: String, tokens: Int)] {
        lock.lock(); defer { lock.unlock() }

        var whereClauses: [String] = ["timestamp >= ?2"]
        var binds: [(index: Int32, value: Any)] = [(2, sinceTimestamp)]
        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = trimmedSource, !source.isEmpty {
            whereClauses.append("source_id = ?3 COLLATE NOCASE")
            binds.append((3, source))
        }

        let sql = """
        SELECT (timestamp - ?1) / 3600000 AS hour_index,
               model,
               SUM(total_tokens) AS sum_tokens
        FROM unified_token_records
        WHERE \(whereClauses.joined(separator: " AND "))
          AND model IS NOT NULL AND model != ''
        GROUP BY hour_index, model
        HAVING sum_tokens > 0;
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 31, description: "hourly model buckets statement")
        sqlite3_bind_int64(stmt, 1, originTimestamp)
        for bind in binds {
            if let intVal = bind.value as? Int64 {
                sqlite3_bind_int64(stmt, bind.index, intVal)
            } else if let strVal = bind.value as? String {
                sqlite3_bind_text(stmt, bind.index, (strVal as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
        }

        var result: [(hourIndex: Int, model: String, tokens: Int)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let hourIndex = Int(sqlite3_column_int64(stmt, 0))
                let model = String(cString: sqlite3_column_text(stmt, 1))
                let tokens = Int(sqlite3_column_int64(stmt, 2))
                result.append((hourIndex: hourIndex, model: model, tokens: tokens))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 32, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch hourly model buckets: \(lastErrorMessage())"])
            }
        }
        return result
    }

    /// Aggregates tokens per (day, model) over an inclusive `yyyy-MM-dd`
    /// range, matching the `dayKey` format of `DailyRollup`. Rows with
    /// NULL/empty models are excluded (same rule as `fetchModelDistribution`),
    /// as are zero-token groups so callers only ever see models that actually
    /// consumed tokens.
    public func fetchDailyModelBuckets(
        startDate: String,
        endDate: String,
        sourceId: String? = nil
    ) throws -> [(dayKey: String, model: String, tokens: Int)] {
        lock.lock(); defer { lock.unlock() }

        var whereClauses: [String] = ["day_key >= ?1", "day_key <= ?2"]
        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = trimmedSource, !source.isEmpty {
            whereClauses.append("source_id = ?3 COLLATE NOCASE")
        }

        let sql = """
        SELECT day_key,
               model,
               SUM(total_tokens) AS sum_tokens
        FROM unified_token_records
        WHERE \(whereClauses.joined(separator: " AND "))
          AND model IS NOT NULL AND model != ''
        GROUP BY day_key, model
        HAVING sum_tokens > 0
        ORDER BY day_key ASC;
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 33, description: "daily model buckets statement")
        sqlite3_bind_text(stmt, 1, (startDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (endDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let source = trimmedSource, !source.isEmpty {
            sqlite3_bind_text(stmt, 3, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        var result: [(dayKey: String, model: String, tokens: Int)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let dayKey = String(cString: sqlite3_column_text(stmt, 0))
                let model = String(cString: sqlite3_column_text(stmt, 1))
                let tokens = Int(sqlite3_column_int64(stmt, 2))
                result.append((dayKey: dayKey, model: model, tokens: tokens))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 34, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch daily model buckets: \(lastErrorMessage())"])
            }
        }
        return result
    }

    public func fetchToolDistribution(
        sourceId: String? = nil,
        sinceTimestamp: Int64? = nil
    ) throws -> [(tool: String, tokens: Int, costUSD: Double)] {
        lock.lock(); defer { lock.unlock() }

        var whereClauses: [String] = []
        var binds: [Any] = []
        if let since = sinceTimestamp {
            whereClauses.append("timestamp >= ?")
            binds.append(since)
        }
        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = trimmedSource, !source.isEmpty {
            whereClauses.append("source_id = ? COLLATE NOCASE")
            binds.append(source)
        }

        let whereString = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT source_id, SUM(total_tokens) AS sum_tokens, SUM(cost_usd) AS sum_cost
        FROM unified_token_records
        \(whereString)
        GROUP BY source_id
        ORDER BY sum_tokens DESC;
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 29, description: "tool distribution statement")
        var bindIndex: Int32 = 1
        for val in binds {
            if let intVal = val as? Int64 {
                sqlite3_bind_int64(stmt, bindIndex, intVal)
            } else if let strVal = val as? String {
                sqlite3_bind_text(stmt, bindIndex, (strVal as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            bindIndex += 1
        }

        var result: [(tool: String, tokens: Int, costUSD: Double)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let tool = String(cString: sqlite3_column_text(stmt, 0))
                let tokens = Int(sqlite3_column_int64(stmt, 1))
                let costUSD = sqlite3_column_double(stmt, 2)
                result.append((tool: tool, tokens: tokens, costUSD: costUSD))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw NSError(domain: "DatabaseManager", code: 30, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch tool distribution: \(lastErrorMessage())"])
            }
        }
        return result
    }

    public struct PeriodTotals: Sendable, Equatable {
        public let totalTokens: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let totalCostUSD: Double

        public init(
            totalTokens: Int = 0,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            totalCostUSD: Double = 0.0
        ) {
            self.totalTokens = totalTokens
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.totalCostUSD = totalCostUSD
        }
    }

    public func fetchPeriodTotals(
        startDate: String? = nil,
        endDate: String? = nil,
        year: Int? = nil,
        sinceTimestamp: Int64? = nil,
        sourceId: String? = nil
    ) throws -> PeriodTotals {
        lock.lock(); defer { lock.unlock() }
        let filterApplied = sourceId != nil && !sourceId!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trimmedSource = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)

        var whereClauses: [String] = []
        var bindValues: [Any] = []

        if let sinceTimestamp = sinceTimestamp {
            whereClauses.append("timestamp >= ?")
            bindValues.append(sinceTimestamp)
        } else if let year = year {
            // Half-open range instead of `LIKE '<year>-%'` so the predicate can use
            // the `day_key` index (U-06); `day_key` is a zero-padded `yyyy-MM-dd`
            // string, so ordering is lexical and the range is equivalent.
            whereClauses.append("day_key >= ? AND day_key < ?")
            bindValues.append("\(year)-01-01")
            bindValues.append("\(year + 1)-01-01")
        } else if let startDate = startDate, let endDate = endDate {
            whereClauses.append("day_key >= ? AND day_key <= ?")
            bindValues.append(startDate)
            bindValues.append(endDate)
        }

        if filterApplied, let source = trimmedSource {
            whereClauses.append("source_id = ? COLLATE NOCASE")
            bindValues.append(source)
        }

        let whereString = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")
        let sql = """
        SELECT
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(output_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_write_tokens), 0),
            COALESCE(SUM(cost_usd), 0.0)
        FROM unified_token_records
        \(whereString);
        """

        let stmt = try cachedStatement(sql: sql, errorCode: 21, description: "period totals statement")

        var bindIndex: Int32 = 1
        for val in bindValues {
            if let intVal = val as? Int64 {
                sqlite3_bind_int64(stmt, bindIndex, intVal)
            } else if let strVal = val as? String {
                sqlite3_bind_text(stmt, bindIndex, (strVal as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            bindIndex += 1
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let totalTokens = Int(sqlite3_column_int64(stmt, 0))
            let inputTokens = Int(sqlite3_column_int64(stmt, 1))
            let outputTokens = Int(sqlite3_column_int64(stmt, 2))
            let cacheReadTokens = Int(sqlite3_column_int64(stmt, 3))
            let cacheWriteTokens = Int(sqlite3_column_int64(stmt, 4))
            let totalCostUSD = sqlite3_column_double(stmt, 5)
            return PeriodTotals(
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                totalCostUSD: totalCostUSD
            )
        }

        return PeriodTotals()
    }

    public func rebuildDailyRollups() throws {
        lock.lock(); defer { lock.unlock() }
        try execute(sql: "BEGIN TRANSACTION;")
        do {
            try execute(sql: "DELETE FROM daily_rollups;")
            let sql = """
            INSERT INTO daily_rollups (day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd)
            SELECT day_key, source_id, SUM(total_tokens), SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens + cache_write_tokens), SUM(cost_usd)
            FROM unified_token_records
            GROUP BY day_key, source_id;
            """
            try execute(sql: sql)
            try execute(sql: "COMMIT;")
            rollupsRevision += 1
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public func clearAllRecords() throws {
        lock.lock(); defer { lock.unlock() }
        try execute(sql: "BEGIN TRANSACTION;")
        do {
            try execute(sql: "DELETE FROM unified_token_records;")
            try execute(sql: "DELETE FROM daily_rollups;")
            try execute(sql: "DELETE FROM sync_cursors;")
            try execute(sql: "COMMIT;")
            rollupsRevision += 1
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public func resetRecords(for sourceId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute(sql: "BEGIN TRANSACTION;")
        do {
            let deleteRecords = "DELETE FROM unified_token_records WHERE source_id = ?;"
            var stmt1: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteRecords, -1, &stmt1, nil) == SQLITE_OK else {
                throw NSError(domain: "DatabaseManager", code: 10, userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
            }
            sqlite3_bind_text(stmt1, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt1)
            sqlite3_finalize(stmt1)

            let deleteRollups = "DELETE FROM daily_rollups WHERE source_id = ?;"
            var stmt2: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteRollups, -1, &stmt2, nil) == SQLITE_OK else {
                throw NSError(domain: "DatabaseManager", code: 11, userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
            }
            sqlite3_bind_text(stmt2, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt2)
            sqlite3_finalize(stmt2)

            let deleteCursors = "DELETE FROM sync_cursors WHERE source_id = ?;"
            var stmt3: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteCursors, -1, &stmt3, nil) == SQLITE_OK else {
                throw NSError(domain: "DatabaseManager", code: 12, userInfo: [NSLocalizedDescriptionKey: lastErrorMessage()])
            }
            sqlite3_bind_text(stmt3, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt3)
            sqlite3_finalize(stmt3)

            try execute(sql: "COMMIT;")
            rollupsRevision += 1
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }
}
