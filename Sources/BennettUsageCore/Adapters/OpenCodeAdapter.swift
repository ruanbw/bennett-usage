import Foundation
import SQLite3

/// Adapter for OpenCode (SST terminal agent).
///
/// Current builds persist history in SQLite at
/// `${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-~/.local/share}/opencode}/opencode.db`.
/// V2 keeps messages in `session_message` (role in the `type` column, JSON
/// payload in `data`) with session metadata in `session_v2`; V1 used
/// `message` / `session` with the role inside the JSON. Databases that have
/// not been migrated yet are still read through the V1 path, and even older
/// builds that wrote JSON files instead (`storage/message/{session}/msg_*.json`
/// + `storage/session/{project}/{session}.json`) are the last fallback.
///
/// Only assistant messages with positive usage become records, so compaction
/// markers (`compaction` parts on synthetic user messages), `idle` markers and
/// `step-start`/`step-finish` streaming noise never inflate counts. Stored
/// `cost: 0` means "not billed", not a $0 invoice — pricing is rebuilt from
/// tokens by `PricingEngine`.
///
/// Record ids (`opencode_<messageId>`) are content-addressed; the SQLite
/// cursor is the last consumed `rowid` (append-only table, stable across
/// reads), plus the rowids of assistant rows whose turn is still streaming
/// (those are updated in place, so they must stay re-readable). A live
/// database may lag behind `-wal` frames — reads stay read-only and pick the
/// rows up once checkpointed.
public struct OpenCodeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "opencode"
    public let displayName: String = "OpenCode"
    public let brandColorHex: String = "#000000"
    public let sfSymbolIcon: String = "terminal"
    public let defaultPath: String = "~/.local/share/opencode"

    public init() {}

    public static func resolveDataDir() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"]?
            .split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let legacy = ProcessInfo.processInfo.environment["OPENCODE_DATA"],
           !legacy.isEmpty {
            let url = URL(fileURLWithPath: (legacy as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            let url = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("opencode")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: ("~/.local/share/opencode" as NSString).expandingTildeInPath)
    }

    public func detectDefaultPath() -> URL? {
        // Honor explicit env overrides first (custom data roots), then the
        // default location.
        let env = ProcessInfo.processInfo.environment
        for key in ["OPENCODE_DATA_DIR", "OPENCODE_DATA"] {
            if let raw = env[key]?.split(separator: ",").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            let url = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("opencode")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let url = Self.resolveDataDir()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var previousOffsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            previousOffsets = dict
        }
        let dbUrl = directory.appendingPathComponent("opencode.db")
        if FileManager.default.fileExists(atPath: dbUrl.path),
           let tables = Self.tableNames(dbUrl) {
            // V2 (`session_message` + `session_v2`) is the current layout; V1
            // (`message` + `session`) is still read for databases that have not
            // been migrated. Anything else falls through to the JSON files.
            if tables.contains("session_message") {
                return try fetchFromV2Database(dbUrl, previousOffsets: previousOffsets)
            }
            if tables.contains("message") {
                return try fetchFromV1Database(dbUrl, previousOffsets: previousOffsets)
            }
        }
        return try fetchFromMessageFiles(directory, previousOffsets: previousOffsets)
    }

    // MARK: - SQLite backend

    /// Table names in `dbUrl`, or `nil` when the file is not a readable SQLite
    /// database (in-progress writes, a directory, some other file format).
    private static func tableNames(_ dbUrl: URL) -> Set<String>? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbUrl.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                names.insert(name)
            }
        }
        return names
    }

    private func tableColumns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        var cols = Set<String>()
        var stmt: OpaquePointer?
        // Table name comes from our own constant, never user input.
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return cols
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) {
                cols.insert(name)
            }
        }
        return cols
    }

    private func fetchFromV1Database(
        _ dbUrl: URL,
        previousOffsets: [String: Int64]
    ) throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets = previousOffsets
        let rowidKey = dbUrl.path + "::rowid"
        let lastRowid = previousOffsets[rowidKey] ?? 0

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbUrl.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open OpenCode database"
            throw NSError(domain: "OpenCodeAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Session directory fallback map (child subagent rows share the
        // parent's directory via parent_id only in discovery; for token
        // records the message timestamp + model is what matters).
        var sessionDirs: [String: String] = [:]
        let sessionCols = tableColumns(db, "session")
        if sessionCols.contains("id") {
            let dirExpr = sessionCols.contains("directory") ? "directory" : "NULL"
            var sstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, \(dirExpr) FROM session;", -1, &sstmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(sstmt) }
                while sqlite3_step(sstmt) == SQLITE_ROW {
                    guard let sid = sqlite3_column_text(sstmt, 0).map({ String(cString: $0) }) else { continue }
                    if let dir = sqlite3_column_text(sstmt, 1).map({ String(cString: $0) }), !dir.isEmpty {
                        sessionDirs[sid] = dir
                    }
                }
            }
        }

        let messageCols = tableColumns(db, "message")
        guard messageCols.contains("id"), messageCols.contains("session_id"), messageCols.contains("data") else {
            // Schema without the expected columns: fall back to JSON files.
            return try fetchFromMessageFiles(dbUrl.deletingLastPathComponent(), previousOffsets: previousOffsets)
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, id, session_id, data FROM message WHERE rowid > ? ORDER BY rowid ASC;", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare OpenCode query"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastRowid)

        var records: [UnifiedTokenRecord] = []
        var maxRowid = lastRowid
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            if rowid > maxRowid { maxRowid = rowid }
            guard let messageId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let sessionId = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else { continue }
            let bytes = sqlite3_column_blob(stmt, 3)
            let size = sqlite3_column_bytes(stmt, 3)
            guard let bytes, size > 0,
                  let data = try? JSONSerialization.jsonObject(
                    with: Data(bytes: bytes, count: Int(size))) as? [String: Any] else { continue }
            guard let record = Self.makeRecord(
                messageId: messageId, sessionId: sessionId, data: data,
                projectFallback: sessionDirs[sessionId], sourceId: sourceId) else { continue }
            records.append(record)
        }
        offsets[rowidKey] = maxRowid
        return (records, .fileOffsets(offsets))
    }

    // MARK: - SQLite V2 backend (`session_message`)

    /// V2 stores the role in `session_message.type` (`user` / `assistant` /
    /// `idle`) instead of the JSON payload, and moved `directory` from the
    /// session row into `session_v2`.
    private func fetchFromV2Database(
        _ dbUrl: URL,
        previousOffsets: [String: Int64]
    ) throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets = previousOffsets
        let rowidKey = dbUrl.path + "::rowid"
        // Rowids of assistant rows whose turn was still streaming when they
        // were last read: they are updated in place, so they have to be
        // re-queried until they carry a finished turn.
        let pendingPrefix = dbUrl.path + "::pending::"
        let lastRowid = previousOffsets[rowidKey] ?? 0
        let pending = Set(previousOffsets.keys.compactMap { key -> Int64? in
            guard key.hasPrefix(pendingPrefix) else { return nil }
            return Int64(key.dropFirst(pendingPrefix.count))
        })

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbUrl.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open OpenCode database"
            throw NSError(domain: "OpenCodeAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Session directory fallback map (`session_v2.directory`).
        var sessionDirs: [String: String] = [:]
        let sessionCols = tableColumns(db, "session_v2")
        if sessionCols.contains("id"), sessionCols.contains("directory") {
            var sstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, directory FROM session_v2;", -1, &sstmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(sstmt) }
                while sqlite3_step(sstmt) == SQLITE_ROW {
                    guard let sid = sqlite3_column_text(sstmt, 0).map({ String(cString: $0) }) else { continue }
                    if let dir = sqlite3_column_text(sstmt, 1).map({ String(cString: $0) }), !dir.isEmpty {
                        sessionDirs[sid] = dir
                    }
                }
            }
        }

        var sql = "SELECT rowid, id, session_id, type, data FROM session_message WHERE rowid > ?"
        if !pending.isEmpty {
            sql += " OR rowid IN (" + Array(repeating: "?", count: pending.count).joined(separator: ",") + ")"
        }
        sql += " ORDER BY rowid ASC;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare OpenCode query"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastRowid)
        for (index, rowid) in pending.sorted().enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 2), rowid)
        }

        var records: [UnifiedTokenRecord] = []
        var maxRowid = lastRowid
        var unsettled = Set<Int64>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            if rowid > maxRowid { maxRowid = rowid }
            guard let messageId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let sessionId = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let type = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) else { continue }
            let bytes = sqlite3_column_blob(stmt, 4)
            let size = sqlite3_column_bytes(stmt, 4)
            guard let bytes, size > 0,
                  let data = try? JSONSerialization.jsonObject(
                    with: Data(bytes: bytes, count: Int(size))) as? [String: Any] else { continue }
            if type == "assistant", !Self.isSettled(data) {
                unsettled.insert(rowid)
                continue
            }
            guard let record = Self.makeRecord(
                messageId: messageId, sessionId: sessionId, data: data,
                projectFallback: sessionDirs[sessionId], sourceId: sourceId,
                role: type) else { continue }
            records.append(record)
        }
        offsets[rowidKey] = maxRowid
        for key in Array(offsets.keys) where key.hasPrefix(pendingPrefix) {
            offsets.removeValue(forKey: key)
        }
        for rowid in unsettled {
            offsets[pendingPrefix + String(rowid)] = 1
        }
        return (records, .fileOffsets(offsets))
    }

    /// `false` while a turn is still streaming. V2 inserts the assistant row as
    /// soon as the turn starts (with `time.streamed` and no `tokens` yet) and
    /// updates it in place when the provider finishes, so an open row must not
    /// advance the cursor past itself.
    static func isSettled(_ data: [String: Any]) -> Bool {
        if data["finish"] != nil { return true }
        if data["error"] != nil { return true }
        if let time = data["time"] as? [String: Any], time["completed"] != nil { return true }
        return false
    }

    // MARK: - Legacy JSON backend

    private func fetchFromMessageFiles(
        _ rootDirectory: URL,
        previousOffsets: [String: Int64]
    ) throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets = previousOffsets
        var records: [UnifiedTokenRecord] = []
        let fileManager = FileManager.default
        let messageRoot = rootDirectory.appendingPathComponent("storage/message")
        let scanRoot = fileManager.fileExists(atPath: messageRoot.path) ? messageRoot : rootDirectory
        let enumerator = fileManager.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        var seenPaths = Set<String>()
        // Session directory fallback from storage/session/*/*.json.
        var sessionDirs: [String: String] = [:]
        if let sessionEnum = fileManager.enumerator(
            at: rootDirectory.appendingPathComponent("storage/session"),
            includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = sessionEnum.nextObject() as? URL {
                guard url.pathExtension == "json" else { continue }
                guard let data = fileManager.contents(atPath: url.path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let sid = (json["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
                if let dir = json["directory"] as? String, !dir.isEmpty {
                    sessionDirs[sid] = dir
                }
            }
        }

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "json" else { continue }
            let fileName = fileUrl.lastPathComponent
            guard fileName.hasPrefix("msg_") else { continue }
            let resourceValues = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let path = fileUrl.path
            seenPaths.insert(path)
            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            if fileSize > 0, fileSize == (previousOffsets[path] ?? -1) { continue }
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                offsets[path] = fileSize
                continue
            }
            // Parent folder is the session id in storage/message/{session}/.
            let sessionId = (json["sessionID"] as? String)
                ?? (json["sessionId"] as? String)
                ?? fileUrl.deletingLastPathComponent().lastPathComponent
            let messageId = (json["id"] as? String)
                ?? fileUrl.deletingPathExtension().lastPathComponent
            if let record = Self.makeRecord(
                messageId: messageId, sessionId: sessionId, data: json,
                projectFallback: sessionDirs[sessionId], sourceId: sourceId) {
                records.append(record)
            }
            offsets[path] = fileSize
        }
        offsets = offsets.filter { key, _ in
            if key.hasSuffix("::rowid") { return true }
            return seenPaths.contains(key)
        }
        return (records, .fileOffsets(offsets))
    }

    // MARK: - Shared message mapping

    static func makeRecord(
        messageId: String,
        sessionId: String,
        data: [String: Any],
        projectFallback: String?,
        sourceId: String,
        role: String? = nil
    ) -> UnifiedTokenRecord? {
        // V2 keeps the role in `session_message.type` rather than the payload,
        // so database callers pass it in; file callers leave it nil.
        guard (role ?? (data["role"] as? String)) == "assistant" else { return nil }
        // Compaction summaries ride as non-assistant content; anything with a
        // compaction marker is never a billable turn.
        if data["compaction"] != nil { return nil }

        let usage = (data["usage"] as? [String: Any])
            ?? (data["tokens"] as? [String: Any])
            ?? data
        let input = intValue(usage["input_tokens"] ?? usage["inputTokens"] ?? usage["input"] ?? usage["prompt_tokens"] ?? usage["promptTokens"])
        var output = intValue(usage["output_tokens"] ?? usage["outputTokens"] ?? usage["output"] ?? usage["completion_tokens"] ?? usage["completionTokens"])
        var cacheRead = intValue(usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"] ?? usage["cached_tokens"] ?? usage["cachedTokens"] ?? usage["cache_read"] ?? usage["cacheRead"])
        var cacheWrite = intValue(usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"] ?? usage["cache_write"] ?? usage["cacheWrite"])
        if let cache = usage["cache"] as? [String: Any] {
            if cacheRead == 0 {
                cacheRead = intValue(cache["read"] ?? cache["readInputTokens"] ?? cache["input"])
            }
            if cacheWrite == 0 {
                cacheWrite = intValue(cache["write"] ?? cache["writeInputTokens"] ?? cache["creation"])
            }
        }
        // OpenCode reports reasoning next to output, not inside it (`session_v2`
        // aggregates prove it: tokens_output 3364 vs tokens_reasoning 3627 in
        // the same session). Providers bill reasoning at the output rate, so
        // folding it in keeps totals and cost honest.
        output += intValue(usage["reasoning"] ?? usage["reasoning_tokens"] ?? usage["reasoningTokens"])
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        let model: String
        if let m = data["modelID"] as? String, !m.isEmpty { model = m }
        else if let m = data["modelId"] as? String, !m.isEmpty { model = m }
        else if let m = data["model"] as? String, !m.isEmpty { model = m }
        else if let m = data["model"] as? [String: Any],
                let id = m["id"] as? String, !id.isEmpty { model = id }
        else { model = "opencode" }

        let timestamp = parseTimestamp(
            data["time"] ?? data["created"] ?? data["timeCreated"] ?? data["completed"])
        var project = projectFallback
        if let dir = data["directory"] as? String, !dir.isEmpty { project = dir }
        if let path = data["path"] as? String, !path.isEmpty { project = path }

        return UnifiedTokenRecord(
            id: "opencode_\(messageId)",
            sourceId: sourceId,
            timestamp: timestamp,
            sessionKey: sessionId,
            projectFolder: project,
            model: model,
            provider: nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
    }

    static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return 0
    }

    static func parseTimestamp(_ value: Any?) -> Date {
        if let dict = value as? [String: Any] {
            if let created = dict["created"] ?? dict["completed"] {
                return parseTimestamp(created)
            }
            return Date()
        }
        if let ms = value as? Double {
            if ms > 1_000_000_000_000 { return Date(timeIntervalSince1970: ms / 1000.0) }
            if ms > 1_000_000_000 { return Date(timeIntervalSince1970: ms) }
            return Date()
        }
        if let n = value as? NSNumber {
            return parseTimestamp(n.doubleValue)
        }
        if let i = value as? Int {
            return parseTimestamp(Double(i))
        }
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
        }
        return Date()
    }
}
