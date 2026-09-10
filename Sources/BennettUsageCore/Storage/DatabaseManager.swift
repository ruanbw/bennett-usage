import Foundation
import SQLite3

public final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &dbPointer, flags, nil) != SQLITE_OK {
            let errMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw NSError(domain: "DatabaseManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        self.db = dbPointer
        try configureDatabase()
        try createTables()
    }

    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    deinit {
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

    public func insertRecords(
        _ records: [UnifiedTokenRecord],
        updateCursorFor sourceId: String? = nil,
        cursor: SyncCursor? = nil
    ) throws {
        guard !records.isEmpty || cursor != nil else { return }
        lock.lock(); defer { lock.unlock() }

        try execute(sql: "BEGIN TRANSACTION;")
        do {
            let recordSql = """
            INSERT OR IGNORE INTO unified_token_records (
                id, source_id, timestamp, day_key, session_key, project_folder,
                model, provider, input_tokens, output_tokens, cache_read_tokens,
                cache_write_tokens, total_tokens, cost_usd
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var recordStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, recordSql, -1, &recordStmt, nil) == SQLITE_OK {
                for r in records {
                    sqlite3_bind_text(recordStmt, 1, (r.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(recordStmt, 2, (r.sourceId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(recordStmt, 3, Int64(r.timestamp.timeIntervalSince1970 * 1000))
                    sqlite3_bind_text(recordStmt, 4, (r.dayKey as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(recordStmt, 5, (r.sessionKey as NSString).utf8String, -1, nil)
                    if let pf = r.projectFolder {
                        sqlite3_bind_text(recordStmt, 6, (pf as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(recordStmt, 6)
                    }
                    sqlite3_bind_text(recordStmt, 7, (r.model as NSString).utf8String, -1, nil)
                    if let prov = r.provider {
                        sqlite3_bind_text(recordStmt, 8, (prov as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(recordStmt, 8)
                    }
                    sqlite3_bind_int(recordStmt, 9, Int32(r.inputTokens))
                    sqlite3_bind_int(recordStmt, 10, Int32(r.outputTokens))
                    sqlite3_bind_int(recordStmt, 11, Int32(r.cacheReadTokens))
                    sqlite3_bind_int(recordStmt, 12, Int32(r.cacheWriteTokens))
                    sqlite3_bind_int(recordStmt, 13, Int32(r.totalTokens))
                    sqlite3_bind_double(recordStmt, 14, r.rawCostUSD ?? 0.0)

                    _ = sqlite3_step(recordStmt)
                    sqlite3_reset(recordStmt)
                }
                sqlite3_finalize(recordStmt)
            }

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
            if sqlite3_prepare_v2(db, rollupSql, -1, &rollupStmt, nil) == SQLITE_OK {
                for r in records {
                    sqlite3_bind_text(rollupStmt, 1, (r.dayKey as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(rollupStmt, 2, (r.sourceId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(rollupStmt, 3, Int32(r.totalTokens))
                    sqlite3_bind_int(rollupStmt, 4, Int32(r.inputTokens))
                    sqlite3_bind_int(rollupStmt, 5, Int32(r.outputTokens))
                    sqlite3_bind_int(rollupStmt, 6, Int32(r.cacheReadTokens + r.cacheWriteTokens))
                    sqlite3_bind_double(rollupStmt, 7, r.rawCostUSD ?? 0.0)

                    _ = sqlite3_step(rollupStmt)
                    sqlite3_reset(rollupStmt)
                }
                sqlite3_finalize(rollupStmt)
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
                if sqlite3_prepare_v2(db, cursorSql, -1, &cursorStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(cursorStmt, 1, (sourceId as NSString).utf8String, -1, nil)
                    _ = cursorData.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(cursorStmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
                    }
                    sqlite3_bind_int64(cursorStmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
                    _ = sqlite3_step(cursorStmt)
                    sqlite3_finalize(cursorStmt)
                }
            }

            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public func fetchDailyRollups(forYear year: Int) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        let pattern = "\(year)-%"
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key LIKE ? ORDER BY day_key ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        var result: [DailyRollup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayKey = String(cString: sqlite3_column_text(stmt, 0))
            let sourceId = String(cString: sqlite3_column_text(stmt, 1))
            let totalTokens = Int(sqlite3_column_int(stmt, 2))
            let inputTokens = Int(sqlite3_column_int(stmt, 3))
            let outputTokens = Int(sqlite3_column_int(stmt, 4))
            let cacheTokens = Int(sqlite3_column_int(stmt, 5))
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
        }
        return result
    }

    public func fetchCursor(for sourceId: String) throws -> SyncCursor? {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT cursor_payload FROM sync_cursors WHERE source_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sourceId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let bytes = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(bytes))
                return try? JSONDecoder().decode(SyncCursor.self, from: data)
            }
        }
        return nil
    }
}
