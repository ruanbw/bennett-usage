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
    /// Bumped on every mutation of `daily_rollups`; keys the yearly rollup memo below.
    private var rollupsRevision = 0
    private var yearlyRollupsCache: (year: Int, revision: Int, rollups: [DailyRollup])?
    public let path: String

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
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA busy_timeout = 3000;")
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS unified_token_records (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
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
        preparedStatements[sql] = prepared
        return prepared
    }

    public func insertRecords(
        _ records: [UnifiedTokenRecord],
        updateCursorFor sourceId: String? = nil,
        cursor: SyncCursor? = nil
    ) throws {
        guard !records.isEmpty || cursor != nil else { return }
        lock.lock(); defer { lock.unlock() }

        try execute(sql: "BEGIN TRANSACTION;")
        do {
            if !records.isEmpty {
                let recordSql = """
                INSERT OR IGNORE INTO unified_token_records (
                    id, source_id, timestamp, day_key, session_key, project_folder,
                    model, provider, input_tokens, output_tokens, cache_read_tokens,
                    cache_write_tokens, total_tokens, cost_usd
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                var recordStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, recordSql, -1, &recordStmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare record statement: \(lastErrorMessage())"])
                }
                defer { sqlite3_finalize(recordStmt) }

                let rollupSql = """
                INSERT INTO daily_rollups (day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day_key, source_id) DO UPDATE SET
                    total_tokens = total_tokens + excluded.total_tokens,
                    input_tokens = input_tokens + excluded.input_tokens,
                    output_tokens = output_tokens + excluded.output_tokens,
                    cache_tokens = cache_tokens + excluded.cache_tokens,
                    cost_usd = cost_usd + excluded.cost_usd;
                """
                var rollupStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, rollupSql, -1, &rollupStmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare rollup statement: \(lastErrorMessage())"])
                }
                defer { sqlite3_finalize(rollupStmt) }

                for r in records {
                    sqlite3_bind_text(recordStmt, 1, (r.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(recordStmt, 2, (r.sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(recordStmt, 3, Int64(r.timestamp.timeIntervalSince1970 * 1000))
                    sqlite3_bind_text(recordStmt, 4, (r.dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(recordStmt, 5, (r.sessionKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let pf = r.projectFolder {
                        sqlite3_bind_text(recordStmt, 6, (pf as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(recordStmt, 6)
                    }
                    sqlite3_bind_text(recordStmt, 7, (r.model as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let prov = r.provider {
                        sqlite3_bind_text(recordStmt, 8, (prov as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(recordStmt, 8)
                    }
                    sqlite3_bind_int(recordStmt, 9, Int32(r.inputTokens))
                    sqlite3_bind_int(recordStmt, 10, Int32(r.outputTokens))
                    sqlite3_bind_int(recordStmt, 11, Int32(r.cacheReadTokens))
                    sqlite3_bind_int(recordStmt, 12, Int32(r.cacheWriteTokens))
                    sqlite3_bind_int(recordStmt, 13, Int32(r.totalTokens))
                    sqlite3_bind_double(recordStmt, 14, r.rawCostUSD ?? 0.0)

                    let recordStep = sqlite3_step(recordStmt)
                    guard recordStep == SQLITE_DONE else {
                        throw NSError(domain: "DatabaseManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to insert record '\(r.id)': \(lastErrorMessage())"])
                    }
                    let wasInserted = sqlite3_changes(db) > 0
                    sqlite3_reset(recordStmt)

                    if wasInserted {
                        sqlite3_bind_text(rollupStmt, 1, (r.dayKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(rollupStmt, 2, (r.sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int(rollupStmt, 3, Int32(r.totalTokens))
                        sqlite3_bind_int(rollupStmt, 4, Int32(r.inputTokens))
                        sqlite3_bind_int(rollupStmt, 5, Int32(r.outputTokens))
                        sqlite3_bind_int(rollupStmt, 6, Int32(r.cacheReadTokens + r.cacheWriteTokens))
                        sqlite3_bind_double(rollupStmt, 7, r.rawCostUSD ?? 0.0)

                        let rollupStep = sqlite3_step(rollupStmt)
                        guard rollupStep == SQLITE_DONE else {
                            throw NSError(domain: "DatabaseManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to upsert rollup for record '\(r.id)': \(lastErrorMessage())"])
                        }
                        sqlite3_reset(rollupStmt)
                    }
                }
            }

            if let sourceId = sourceId, let cursor = cursor {
                let cursorData = try JSONEncoder().encode(cursor)
                let cursorSql = """
                INSERT INTO sync_cursors (source_id, cursor_payload, last_synced_at)
                VALUES (?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    cursor_payload = excluded.cursor_payload,
                    last_synced_at = excluded.last_synced_at;
                """
                var cursorStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, cursorSql, -1, &cursorStmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare cursor statement: \(lastErrorMessage())"])
                }
                defer { sqlite3_finalize(cursorStmt) }

                sqlite3_bind_text(cursorStmt, 1, (sourceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                _ = cursorData.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(cursorStmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(cursorStmt, 3, Int64(Date().timeIntervalSince1970 * 1000))

                let cursorStep = sqlite3_step(cursorStmt)
                guard cursorStep == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to step cursor statement: \(lastErrorMessage())"])
                }
            }

            try execute(sql: "COMMIT;")
            if !records.isEmpty { rollupsRevision += 1 }
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public func fetchDailyRollups(forYear year: Int) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        if let cached = yearlyRollupsCache, cached.year == year, cached.revision == rollupsRevision {
            return cached.rollups
        }
        let pattern = "\(year)-%"
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key LIKE ? ORDER BY day_key ASC;"
        let stmt = try cachedStatement(sql: sql, errorCode: 9, description: "daily rollups fetch statement")

        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, SQLITE_TRANSIENT)
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
        SELECT id, source_id, timestamp, day_key, session_key, project_folder, model, provider,
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

        sqlite3_bind_int64(stmt, 1, sinceTimestamp)
        var result: [UnifiedTokenRecord] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let timestamp = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000.0)
                let dayKey = String(cString: sqlite3_column_text(stmt, 3))
                let sessionKey = String(cString: sqlite3_column_text(stmt, 4))
                let projectFolder: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil
                let model = String(cString: sqlite3_column_text(stmt, 6))
                let provider: String? = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
                let inputTokens = Int(sqlite3_column_int(stmt, 8))
                let outputTokens = Int(sqlite3_column_int(stmt, 9))
                let cacheReadTokens = Int(sqlite3_column_int(stmt, 10))
                let cacheWriteTokens = Int(sqlite3_column_int(stmt, 11))
                let rawCostUSD: Double? = sqlite3_column_type(stmt, 13) != SQLITE_NULL ? sqlite3_column_double(stmt, 13) : nil

                result.append(UnifiedTokenRecord(
                    id: id,
                    sourceId: sourceId,
                    timestamp: timestamp,
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

    public func fetchProjectRankings(
        limit: Int = 10,
        sourceId: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        sinceTimestamp: Int64? = nil
    ) throws -> [(project: String, totalTokens: Int, costUSD: Double)] {
        lock.lock(); defer { lock.unlock() }

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
        GROUP BY project_folder
        ORDER BY sum_tokens DESC
        LIMIT ?;
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
        sqlite3_bind_int64(stmt, bindIndex, Int64(limit))

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
        return result
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

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 25, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare model distribution statement: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }

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
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseManager", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare record stats statement: \(lastErrorMessage())"])
        }
        defer { sqlite3_finalize(stmt) }

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
            whereClauses.append("day_key LIKE ?")
            bindValues.append("\(year)-%")
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
