import Foundation
import SQLite3

public struct OmpAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "omp"
    public let displayName: String = "Oh My Pi"
    public let brandColorHex: String = "#3B82F6"
    public let sfSymbolIcon: String = "terminal.fill"
    public let defaultPath: String = "~/.omp/stats.db"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from targetPath: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        let lastId: Int64
        if case .rowId(let id) = cursor {
            lastId = id
        } else {
            lastId = 0
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(targetPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open OMP database"
            throw NSError(domain: "OmpAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 3000)

        let query = """
        SELECT id, entry_id, session_file, folder, model, provider, timestamp,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_total
        FROM messages
        WHERE id > ?
        ORDER BY id ASC
        LIMIT 5000;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "OmpAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare OMP query"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastId)

        var records: [UnifiedTokenRecord] = []
        var maxId = lastId

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let entryId = String(cString: sqlite3_column_text(stmt, 1))
            _ = entryId
            let sessionFile = String(cString: sqlite3_column_text(stmt, 2))
            let folder = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let model = String(cString: sqlite3_column_text(stmt, 4))
            let provider = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let timestampMs = sqlite3_column_int64(stmt, 6)
            let inputTokens = Int(sqlite3_column_int(stmt, 7))
            let outputTokens = Int(sqlite3_column_int(stmt, 8))
            let cacheReadTokens = Int(sqlite3_column_int(stmt, 9))
            let cacheWriteTokens = Int(sqlite3_column_int(stmt, 10))
            let costTotal = sqlite3_column_double(stmt, 11)

            let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

            let record = UnifiedTokenRecord(
                id: "omp_\(rowId)",
                sourceId: sourceId,
                timestamp: date,
                sessionKey: sessionFile,
                projectFolder: folder,
                model: model,
                provider: provider,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                rawCostUSD: costTotal
            )
            records.append(record)
            if rowId > maxId { maxId = rowId }
        }

        return (records, .rowId(maxId))
    }
}
