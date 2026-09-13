import Foundation
import SQLite3

public struct OmpAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "omp"
    public let displayName: String = "Oh My Pi"
    public let brandColorHex: String = "#3B82F6"
    public let sfSymbolIcon: String = "terminal.fill"
    public let defaultPath: String = "~/.omp/agent/sessions"

    public init() {}

    /// ASCII bytes of the `"usage"` and `"session"` keys. A JSONL line can
    /// only yield a token record when it carries a `usage` object, and only
    /// `type:"session"` headers update the session context, so a cheap byte
    /// scan lets every other line skip the JSON parse + NSNumber bridging
    /// pass. (The `"session"` marker also matches the header, whose string
    /// value is necessarily present verbatim.)
    private static let usageKey = Data("\"usage\"".utf8)
    private static let sessionKey = Data("\"session\"".utf8)

    public func detectDefaultPath() -> URL? {
        let sessionsPath = ("~/.omp/agent/sessions" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: sessionsPath) {
            return URL(fileURLWithPath: sessionsPath)
        }
        let dbPath = ("~/.omp/stats.db" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: dbPath) {
            return URL(fileURLWithPath: dbPath)
        }
        return nil
    }

    public func fetchIncrementalRecords(
        from targetPath: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetPath.path, isDirectory: &isDir), isDir.boolValue {
            return try await fetchIncrementalJsonlRecords(from: targetPath, since: cursor)
        } else if targetPath.pathExtension == "db" || !isDir.boolValue {
            return try await fetchIncrementalSqliteRecords(from: targetPath, since: cursor)
        } else {
            return try await fetchIncrementalJsonlRecords(from: targetPath, since: cursor)
        }
    }

    private func fetchIncrementalSqliteRecords(
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
            // entry_id (column 1) is not needed; do not read it —
            // String(cString:) would crash on a NULL column.
            // Columns 2 (session_file) and 4 (model) are read defensively:
            // NULL there must fall back instead of crashing.
            let sessionFile = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let folder = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
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

    private func fetchIncrementalJsonlRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            offsets = dict
        }

        var records: [UnifiedTokenRecord] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "jsonl" else { continue }
            let filePath = fileUrl.resolvingSymlinksInPath().path
            let lastOffset = offsets[filePath] ?? offsets[fileUrl.path] ?? 0

            // Pre-fetched via includingPropertiesForKeys: avoids a
            // lstat/listxattr/getxattr round-trip per file on every sync.
            let fileSize = Int64((try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fileSize <= lastOffset { continue }

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }
            var sessionCwd: String?
            var headerSessionId: String?
            if lastOffset > 0 {
                if let headerData = try? handle.read(upToCount: 2048) {
                    extractSessionMetadata(from: headerData, sessionId: &headerSessionId, cwd: &sessionCwd)
                }
            }

            try handle.seek(toOffset: UInt64(lastOffset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            let folderName = fileUrl.deletingLastPathComponent().lastPathComponent
            let baseCount = records.count
            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex

            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                currentOffset += Int64(lineData.count + 1)

                guard !lineData.isEmpty else { continue }
                if lineData.range(of: Self.usageKey) == nil,
                   lineData.range(of: Self.sessionKey) == nil {
                    continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                if let type = json["type"] as? String, type == "session" {
                    if let sid = json["id"] as? String {
                        headerSessionId = sid
                    }
                    if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                        sessionCwd = cwd
                    }
                    continue
                }

                let message = json["message"] as? [String: Any]
                guard let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) else {
                    continue
                }

                let promptTokens = (usage["input"] as? Int)
                    ?? (usage["prompt_tokens"] as? Int)
                    ?? (usage["input_tokens"] as? Int)
                    ?? ((usage["input"] as? NSNumber)?.intValue)
                    ?? ((usage["prompt_tokens"] as? NSNumber)?.intValue)
                    ?? ((usage["input_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let completionTokens = (usage["output"] as? Int)
                    ?? (usage["completion_tokens"] as? Int)
                    ?? (usage["output_tokens"] as? Int)
                    ?? ((usage["output"] as? NSNumber)?.intValue)
                    ?? ((usage["completion_tokens"] as? NSNumber)?.intValue)
                    ?? ((usage["output_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let cacheRead = (usage["cacheRead"] as? Int)
                    ?? (usage["cache_read_tokens"] as? Int)
                    ?? ((usage["cacheRead"] as? NSNumber)?.intValue)
                    ?? ((usage["cache_read_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let cacheWrite = (usage["cacheWrite"] as? Int)
                    ?? (usage["cache_write_tokens"] as? Int)
                    ?? ((usage["cacheWrite"] as? NSNumber)?.intValue)
                    ?? ((usage["cache_write_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let rawCost: Double?
                if let costDict = usage["cost"] as? [String: Any] {
                    if let d = costDict["total"] as? Double {
                        rawCost = d
                    } else if let num = costDict["total"] as? NSNumber {
                        rawCost = num.doubleValue
                    } else {
                        rawCost = nil
                    }
                } else if let costVal = usage["cost"] as? Double {
                    rawCost = costVal
                } else if let num = usage["cost"] as? NSNumber {
                    rawCost = num.doubleValue
                } else {
                    rawCost = nil
                }

                let model = (message?["model"] as? String)
                    ?? (json["model"] as? String)
                    ?? "unknown"

                let provider = (message?["provider"] as? String)
                    ?? (json["provider"] as? String)

                var timestamp = Date()
                if let tsStr = (json["timestamp"] as? String) ?? (message?["timestamp"] as? String) {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                } else if let tsNum = (message?["timestamp"] as? NSNumber) ?? (json["timestamp"] as? NSNumber) {
                    timestamp = Date(timeIntervalSince1970: tsNum.doubleValue / 1000.0)
                }

                let projectFolder: String? = sessionCwd ?? (json["cwd"] as? String) ?? folderName
                let effectiveSessionId = headerSessionId ?? fileUrl.deletingPathExtension().lastPathComponent
                let messageId = (json["id"] as? String) ?? "\(currentOffset)"
                let recordId = "omp_\(effectiveSessionId)_\(messageId)"

                let record = UnifiedTokenRecord(
                    id: recordId,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: fileUrl.lastPathComponent,
                    projectFolder: projectFolder,
                    model: model,
                    provider: provider,
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    rawCostUSD: rawCost
                )
                records.append(record)
            }

            // Usage lines that precede the session header in the same file
            // fall back to the directory name; once the header's cwd is known
            // those early rows are rewritten so one session does not fork into
            // a phantom project (e.g. "-tmp" alongside "/Users/x/tmp").
            if let cwd = sessionCwd {
                for i in baseCount..<records.count where records[i].projectFolder == folderName {
                    records[i].projectFolder = cwd
                }
            }

            offsets[filePath] = currentOffset
        }

        return (records, .fileOffsets(offsets))
    }

    private func extractSessionMetadata(from data: Data, sessionId: inout String?, cwd: inout String?) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        for line in content.split(separator: "\n", maxSplits: 5) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "session" else {
                continue
            }
            if let sid = json["id"] as? String { sessionId = sid }
            if let c = json["cwd"] as? String, !c.isEmpty { cwd = c }
            break
        }
    }
}
