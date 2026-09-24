import Foundation
import SQLite3
import CryptoKit

/// Reads Goose's canonical SQLite usage ledger without modifying the source.
///
/// Goose records one `usage_ledger` row per provider invocation. The ledger
/// `input_tokens` value already contains cache reads and writes, while session
/// accumulated values can also contain older usage represented by a
/// `carried_forward` row. Ordinary rows are therefore imported incrementally,
/// and a single deterministic baseline per session preserves any accumulated
/// gap without adding the aggregates, ledger, and carry-forward row together.
public struct GooseAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "goose"
    public let displayName: String = "Goose"
    public let brandColorHex: String = "#CA8A04"
    public let sfSymbolIcon: String = "bird.fill"
    public let defaultPath: String = "~/Library/Application Support/Block/goose/sessions/sessions.db"

    public init() {}

    private static let requiredSchema: [String: Set<String>] = [
        "sessions": [
            "id", "provider_name",
            "accumulated_input_tokens", "accumulated_output_tokens",
            "accumulated_total_tokens", "accumulated_cache_read_tokens",
            "accumulated_cache_write_tokens", "accumulated_cost"
        ],
        "messages": ["id", "session_id"],
        "usage_ledger": [
            "id", "session_id", "created_timestamp", "model",
            "input_tokens", "output_tokens", "total_tokens",
            "cache_read_tokens", "cache_write_tokens", "cost",
            "cost_source", "is_compaction"
        ]
    ]

    // MARK: - Paths

    static func databaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configuredRoot = environment["GOOSE_PATH_ROOT"],
           !configuredRoot.isEmpty,
           URL(fileURLWithPath: configuredRoot).isFileURL,
           configuredRoot.hasPrefix("/") {
            return URL(fileURLWithPath: configuredRoot)
                .appendingPathComponent("data/sessions/sessions.db")
        }
        return URL(fileURLWithPath: ("~/Library/Application Support/Block/goose/sessions/sessions.db" as NSString)
            .expandingTildeInPath)
    }

    static func sessionsRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        databaseURL(environment: environment).deletingLastPathComponent().standardizedFileURL
    }

    public func detectDefaultPath() -> URL? {
        let database = Self.databaseURL().standardizedFileURL
        if FileManager.default.fileExists(atPath: database.path) {
            return database
        }
        let sessions = database.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return sessions
        }
        return nil
    }

    private static func resolveDatabaseURL(_ target: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return target.appendingPathComponent("sessions.db").standardizedFileURL
        }
        return target.standardizedFileURL
    }

    // MARK: - Sync

    public func fetchIncrementalRecords(
        from target: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        let databaseURL = Self.resolveDatabaseURL(target)
        let database = try Self.openReadOnlyDatabase(at: databaseURL)
        defer { sqlite3_close(database) }

        let schemaFingerprint = try Self.validateSchemaAndFingerprint(database)
        let identity = "\(Self.canonicalFileResourceIdentifier(databaseURL))|\(schemaFingerprint)"

        var startAfter: Int64 = 0
        var includeBaselines = true
        if case .databaseIdentity(let cursorIdentity, let cursorRowId) = cursor,
           cursorIdentity == identity {
            let maximumRowId = try Self.maximumRowId(database)
            if maximumRowId < cursorRowId {
                // A same-file watermark can only move backwards after a database
                // rebuild/replacement. The cross-kind result deliberately asks
                // SyncCoordinator's existing cutover path to refetch from nil;
                // the subsequent normal result is databaseIdentity again.
                return ([], .rowId(maximumRowId))
            }
            startAfter = cursorRowId
            includeBaselines = false
        }

        let maxRowId = try Self.maximumRowId(database)
        var records = try Self.fetchOrdinaryLedgerRows(
            database,
            identity: identity,
            after: startAfter)
        if includeBaselines {
            records.insert(
                contentsOf: try Self.fetchSyntheticBaselines(database, identity: identity),
                at: 0
            )
        }
        return (records, .databaseIdentity(identity, maxRowId))
    }

    // MARK: - Read-only SQLite connection and schema

    private static func openReadOnlyDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let database { sqlite3_close(database) }
            throw adapterError(code: 1, message: message)
        }

        let timeoutResult = sqlite3_busy_timeout(database, 3_000)
        guard timeoutResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_close(database)
            throw adapterError(code: 2, message: message)
        }

        do {
            try execute("PRAGMA query_only=ON;", on: database)
        } catch {
            sqlite3_close(database)
            throw error
        }
        return database
    }

    private static func validateSchemaAndFingerprint(_ database: OpaquePointer) throws -> String {
        var signature = ""
        for table in Self.requiredSchema.keys.sorted() {
            let rows = try query("PRAGMA table_xinfo(\(table));", on: database)
            var columns: Set<String> = []
            var details: [[String]] = []
            for row in rows {
                let name = row[1] ?? ""
                columns.insert(name)
                details.append([
                    string(row[0]), name, row[2] ?? "",
                    string(row[3]), row[4] ?? "", string(row[5])
                ])
            }
            let missing = Self.requiredSchema[table]!.subtracting(columns)
            guard missing.isEmpty else {
                throw adapterError(
                    code: 3,
                    message: "Unsupported Goose schema: \(table) is missing \(missing.sorted().joined(separator: ", "))"
                )
            }
            signature += table + "[" + details.map { $0.joined(separator: ":") }.joined(separator: "|") + "]"
        }

        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalFileResourceIdentifier(_ url: URL) -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let values = try? canonicalURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let identifier = values.fileResourceIdentifier {
            if let url = identifier as? URL { return url.standardizedFileURL.absoluteString }
            if let url = identifier as? NSURL, let absoluteURL = url.absoluteURL {
                return absoluteURL.standardizedFileURL.absoluteString
            }
            return String(describing: identifier)
        }
        return canonicalURL.path
    }

    // MARK: - Ledger and synthetic baseline

    private static func maximumRowId(_ database: OpaquePointer) throws -> Int64 {
        let rows = try query("SELECT COALESCE(MAX(id), 0) FROM usage_ledger;", on: database)
        guard let row = rows.first, !row.isEmpty, let value = row[0] else { return 0 }
        return Int64(value) ?? 0
    }

    private static func fetchOrdinaryLedgerRows(
        _ database: OpaquePointer,
        identity: String,
        after rowId: Int64
    ) throws -> [UnifiedTokenRecord] {
        let sql = """
        SELECT l.id, l.session_id, l.created_timestamp, l.model,
               l.input_tokens, l.output_tokens, l.cache_read_tokens,
               l.cache_write_tokens, l.cost, s.provider_name
        FROM usage_ledger AS l
        LEFT JOIN sessions AS s ON s.id = l.session_id
        WHERE l.id > ? AND COALESCE(l.cost_source, '') != 'carried_forward'
        ORDER BY l.id ASC;
        """
        var statement: OpaquePointer?
        try prepare(sql, on: database, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowId)

        var records: [UnifiedTokenRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw adapterError(code: 4, message: "Failed to read usage_ledger: \(lastError(database))")
            }

            let ledgerId = sqlite3_column_int64(statement, 0)
            let sessionId = columnText(statement, 1) ?? ""
            let timestamp = sqlite3_column_int64(statement, 2)
            let model = nonEmpty(columnText(statement, 3)) ?? "unknown"
            let input = sqlite3_column_int64(statement, 4)
            let output = sqlite3_column_int64(statement, 5)
            let cacheRead = sqlite3_column_int64(statement, 6)
            let cacheWrite = sqlite3_column_int64(statement, 7)
            let cost: Double? = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 8)
            let provider = nonEmpty(columnText(statement, 9))

            records.append(UnifiedTokenRecord(
                id: "goose|\(identity)|ledger|\(ledgerId)",
                sourceId: "goose",
                timestamp: Date(timeIntervalSince1970: Double(timestamp)),
                timestampSource: .event,
                sessionKey: sessionId,
                projectFolder: nil,
                model: model,
                provider: provider,
                inputTokens: Int(clamping: max(0, input - cacheRead - cacheWrite)),
                outputTokens: Int(clamping: max(0, output)),
                cacheReadTokens: Int(clamping: max(0, cacheRead)),
                cacheWriteTokens: Int(clamping: max(0, cacheWrite)),
                rawCostUSD: cost
            ))
        }
        return records
    }

    private static func fetchSyntheticBaselines(
        _ database: OpaquePointer,
        identity: String
    ) throws -> [UnifiedTokenRecord] {
        let sql = """
        SELECT s.id, s.provider_name,
               COALESCE(s.accumulated_input_tokens, 0),
               COALESCE(s.accumulated_output_tokens, 0),
               COALESCE(s.accumulated_total_tokens, 0),
               COALESCE(s.accumulated_cache_read_tokens, 0),
               COALESCE(s.accumulated_cache_write_tokens, 0),
               COALESCE(s.accumulated_cost, 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.input_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.output_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.total_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.cache_read_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.cache_write_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                                THEN COALESCE(l.cost, 0) ELSE 0 END), 0),
               MIN(CASE WHEN COALESCE(l.cost_source, '') != 'carried_forward'
                        THEN l.created_timestamp END)
        FROM sessions AS s
        LEFT JOIN usage_ledger AS l ON l.session_id = s.id
        GROUP BY s.id
        ORDER BY s.id ASC;
        """
        let rows = try query(sql, on: database)
        var records: [UnifiedTokenRecord] = []

        for row in rows {
            let sessionId = row[0] ?? ""
            let provider = nonEmpty(row[1])
            let accumulatedOutput = int64(row[3])
            let accumulatedTotal = int64(row[4])
            let accumulatedCacheRead = int64(row[5])
            let accumulatedCacheWrite = int64(row[6])
            let accumulatedCost = double(row[7])
            let ordinaryOutput = int64(row[9])
            let ordinaryTotal = int64(row[10])
            let ordinaryCacheRead = int64(row[11])
            let ordinaryCacheWrite = int64(row[12])
            let ordinaryCost = double(row[13])
            let timestamp = int64(row[14])

            // The accumulated total is the authoritative zero-ledger gap. Split
            // it using only real component differences; the remaining amount
            // is fresh input. This also handles old databases where component
            // columns are absent or inconsistent but the total is trustworthy.
            let totalDelta = max(0, accumulatedTotal - ordinaryTotal)
            var remaining = totalDelta
            let cacheReadDelta = min(max(0, accumulatedCacheRead - ordinaryCacheRead), remaining)
            remaining -= cacheReadDelta
            let cacheWriteDelta = min(max(0, accumulatedCacheWrite - ordinaryCacheWrite), remaining)
            remaining -= cacheWriteDelta
            let outputDelta = min(max(0, accumulatedOutput - ordinaryOutput), remaining)
            let freshInputDelta = remaining - outputDelta
            let costDelta = max(0, accumulatedCost - ordinaryCost)
            guard totalDelta > 0 || costDelta > 0 else { continue }

            let encodedSession = Data(sessionId.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            records.append(UnifiedTokenRecord(
                id: "goose|\(identity)|baseline|\(encodedSession)",
                sourceId: "goose",
                timestamp: Date(timeIntervalSince1970: Double(timestamp)),
                timestampSource: .event,
                sessionKey: sessionId,
                projectFolder: nil,
                model: "goose",
                provider: provider,
                inputTokens: Int(clamping: freshInputDelta),
                outputTokens: Int(clamping: outputDelta),
                cacheReadTokens: Int(clamping: cacheReadDelta),
                cacheWriteTokens: Int(clamping: cacheWriteDelta),
                rawCostUSD: costDelta > 0 ? costDelta : nil
            ))
        }
        return records
    }

    // MARK: - SQLite value helpers

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError(database)
            sqlite3_free(errorMessage)
            throw adapterError(code: 5, message: message)
        }
    }

    private static func query(_ sql: String, on database: OpaquePointer) throws -> [[String?]] {
        var statement: OpaquePointer?
        try prepare(sql, on: database, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw adapterError(code: 6, message: "SQLite query failed: \(lastError(database))")
            }
            rows.append((0..<sqlite3_column_count(statement)).map { columnText(statement, $0) })
        }
    }

    private static func prepare(
        _ sql: String,
        on database: OpaquePointer,
        statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw adapterError(code: 7, message: "SQLite prepare failed: \(lastError(database))")
        }
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func int64(_ value: String?) -> Int64 { Int64(value ?? "") ?? 0 }
    private static func double(_ value: String?) -> Double { Double(value ?? "") ?? 0 }
    private static func string(_ value: String?) -> String { value ?? "" }

    private static func lastError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func adapterError(code: Int32, message: String) -> NSError {
        NSError(domain: "GooseAdapter", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
