import Foundation
import SQLite3
import CryptoKit

/// Reads Goose's canonical SQLite usage ledger without modifying the source.
///
/// Goose records one `usage_ledger` row per provider invocation. The ledger
/// `input_tokens` value already contains cache reads and writes, while session
/// accumulated values can also contain older usage represented by a
/// `carried_forward` row. Ordinary rows are therefore imported incrementally,
/// while a single deterministic baseline per session reconciles against that
/// session's own ledger. Carry-forward rows contribute to reconciliation but
/// are not emitted as provider invocations.
public struct GooseAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "goose"
    public let displayName: String = "Goose"
    public let brandColorHex: String = "#CA8A04"
    public let sfSymbolIcon: String = "bird.fill"
    public let defaultPath: String = "~/Library/Application Support/Block/goose/sessions/sessions.db"

    public init() {}

    private static let requiredSchema: [String: Set<String>] = [
        "sessions": [
            "id", "provider_name", "parent_session_id",
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

        let schema = try Self.validateSchemaAndFingerprint(database)
        let identity = "\(Self.canonicalFileResourceIdentifier(databaseURL))|\(schema.fingerprint)"

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
                contentsOf: try Self.fetchSyntheticBaselines(database, identity: identity, schema: schema),
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

    private struct SchemaInfo {
        let fingerprint: String
        let hasCreatedAt: Bool
        let hasUpdatedAt: Bool
    }

    private static func validateSchemaAndFingerprint(_ database: OpaquePointer) throws -> SchemaInfo {
        var signature = ""
        var sessionColumns: Set<String> = []
        let optionalSessionColumns: Set<String> = ["created_at", "updated_at"]
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
            if table == "sessions" { sessionColumns = columns }
            // parent_session_id was added after the first Goose schema. It is
            // part of the canonical schema, but older databases remain valid;
            // the baseline path treats every legacy session as a root.
            let allowedMissing = table == "sessions"
                ? Set(["parent_session_id"]).union(optionalSessionColumns)
                : []
            let missing = Self.requiredSchema[table]!.subtracting(columns).subtracting(allowedMissing)
            guard missing.isEmpty else {
                throw adapterError(
                    code: 3,
                    message: "Unsupported Goose schema: \(table) is missing \(missing.sorted().joined(separator: ", "))"
                )
            }
            signature += table + "[" + details.map { $0.joined(separator: ":") }.joined(separator: "|") + "]"
        }

        let digest = SHA256.hash(data: Data(signature.utf8))
        return SchemaInfo(
            fingerprint: digest.map { String(format: "%02x", $0) }.joined(),
            hasCreatedAt: sessionColumns.contains("created_at"),
            hasUpdatedAt: sessionColumns.contains("updated_at")
        )
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
               l.input_tokens, l.output_tokens, l.total_tokens,
               l.cache_read_tokens, l.cache_write_tokens, l.cost, s.provider_name
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
            let input: Int64? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 4)
            let output: Int64? = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 5)
            let total: Int64? = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 6)
            let cacheRead: Int64? = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 7)
            let cacheWrite: Int64? = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 8)
            // A NULL token column means unknown, not zero. Do not create a
            // synthetic zero-token ledger row when every usage field is NULL.
            guard input != nil || output != nil || total != nil || cacheRead != nil || cacheWrite != nil else { continue }
            let cost: Double? = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 9)
            let provider = nonEmpty(columnText(statement, 10))
            let knownInput = input ?? 0
            let knownOutput = output ?? 0
            let knownCacheRead = cacheRead ?? 0
            let knownCacheWrite = cacheWrite ?? 0
            // If Goose supplied only a total, retain that known usage rather
            // than silently turning it into an empty record. Component NULLs
            // remain zero, while available components are used as-is.
            let freshInput: Int64
            if input == nil && output == nil && cacheRead == nil && cacheWrite == nil {
                freshInput = max(0, total ?? 0)
            } else {
                freshInput = max(0, knownInput - knownCacheRead - knownCacheWrite)
            }

            records.append(UnifiedTokenRecord(
                id: "goose|\(identity)|ledger|\(ledgerId)",
                sourceId: "goose",
                timestamp: Date(timeIntervalSince1970: Double(timestamp)),
                timestampSource: .event,
                sessionKey: sessionId,
                projectFolder: nil,
                model: model,
                provider: provider,
                inputTokens: Int(clamping: freshInput),
                outputTokens: Int(clamping: max(0, knownOutput)),
                cacheReadTokens: Int(clamping: max(0, knownCacheRead)),
                cacheWriteTokens: Int(clamping: max(0, knownCacheWrite)),
                rawCostUSD: cost
            ))
        }
        return records
    }

    private struct LedgerUsage {
        var input: Int64 = 0
        var output: Int64 = 0
        var total: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var cost: Double = 0
        var timestamp: Int64?
    }

    private struct SessionUsage {
        let id: String
        let provider: String?
        let accumulatedInput: Int64
        let accumulatedOutput: Int64
        let accumulatedTotal: Int64
        let accumulatedCacheRead: Int64
        let accumulatedCacheWrite: Int64
        let accumulatedCost: Double
        let createdAt: Int64?
        let updatedAt: Int64?
        var ledger: LedgerUsage
    }

    private static let safeBaselineTimestamp = Date(timeIntervalSinceReferenceDate: 0)

    private static func fetchSyntheticBaselines(
        _ database: OpaquePointer,
        identity: String,
        schema: SchemaInfo
    ) throws -> [UnifiedTokenRecord] {
        let createdExpression = schema.hasCreatedAt ? "s.created_at" : "NULL"
        let updatedExpression = schema.hasUpdatedAt ? "s.updated_at" : "NULL"
        let sessionSQL = """
        SELECT s.id, s.provider_name,
               COALESCE(s.accumulated_input_tokens, 0),
               COALESCE(s.accumulated_output_tokens, 0),
               COALESCE(s.accumulated_total_tokens, 0),
               COALESCE(s.accumulated_cache_read_tokens, 0),
               COALESCE(s.accumulated_cache_write_tokens, 0),
               COALESCE(s.accumulated_cost, 0),
               \(createdExpression), \(updatedExpression)
        FROM sessions AS s
        ORDER BY s.id ASC;
        """
        let sessionRows = try query(sessionSQL, on: database)
        let ledgerSQL = """
        SELECT session_id,
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN COALESCE(input_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN COALESCE(output_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN CASE WHEN total_tokens IS NOT NULL
                                          THEN MAX(total_tokens, 0)
                                          ELSE MAX(COALESCE(input_tokens, 0)
                                                   - COALESCE(cache_read_tokens, 0)
                                                   - COALESCE(cache_write_tokens, 0), 0)
                                               + COALESCE(output_tokens, 0)
                                               + COALESCE(cache_read_tokens, 0)
                                               + COALESCE(cache_write_tokens, 0) END
                                ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN COALESCE(cache_read_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN COALESCE(cache_write_tokens, 0) ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN \(Self.hasAnyLedgerUsage)
                                THEN COALESCE(cost, 0) ELSE 0 END), 0),
               MIN(CASE WHEN \(Self.hasAnyLedgerUsage)
                              AND COALESCE(cost_source, '') != 'carried_forward'
                        THEN created_timestamp END)
        FROM usage_ledger
        GROUP BY session_id;
        """
        let ledgerRows = try query(ledgerSQL, on: database)
        var ledgerBySession: [String: LedgerUsage] = [:]
        for row in ledgerRows {
            guard let sessionID = row[0], !sessionID.isEmpty else { continue }
            ledgerBySession[sessionID] = LedgerUsage(
                input: int64(row[1]), output: int64(row[2]), total: int64(row[3]),
                cacheRead: int64(row[4]), cacheWrite: int64(row[5]), cost: double(row[6]),
                timestamp: positiveInt64(row[7])
            )
        }

        var sessions: [String: SessionUsage] = [:]
        for row in sessionRows {
            guard let id = row[0], !id.isEmpty else { continue }
            sessions[id] = SessionUsage(
                id: id, provider: nonEmpty(row[1]),
                accumulatedInput: int64(row[2]), accumulatedOutput: int64(row[3]),
                accumulatedTotal: int64(row[4]), accumulatedCacheRead: int64(row[5]),
                accumulatedCacheWrite: int64(row[6]), accumulatedCost: double(row[7]),
                createdAt: positiveInt64(row[8]), updatedAt: positiveInt64(row[9]),
                ledger: ledgerBySession[id] ?? LedgerUsage()
            )
        }
        var records: [UnifiedTokenRecord] = []
        for id in sessions.keys.sorted() {
            let session = sessions[id]!
            let totalDelta = max(0, session.accumulatedTotal - session.ledger.total)
            var remaining = totalDelta
            let cacheReadDelta = min(max(0, session.accumulatedCacheRead - session.ledger.cacheRead), remaining)
            remaining -= cacheReadDelta
            let cacheWriteDelta = min(max(0, session.accumulatedCacheWrite - session.ledger.cacheWrite), remaining)
            remaining -= cacheWriteDelta
            let outputDelta = min(max(0, session.accumulatedOutput - session.ledger.output), remaining)
            let inputDelta = remaining - outputDelta
            let costDelta = max(0, session.accumulatedCost - session.ledger.cost)
            guard totalDelta > 0 || costDelta > 0 else { continue }
            let timestamp = baselineTimestamp(for: session)
            let encodedSession = Data(session.id.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            records.append(UnifiedTokenRecord(
                id: "goose|\(identity)|baseline|\(encodedSession)",
                sourceId: "goose",
                timestamp: timestamp,
                timestampSource: .event,
                sessionKey: session.id,
                projectFolder: nil,
                model: "goose",
                provider: session.provider,
                inputTokens: Int(clamping: inputDelta),
                outputTokens: Int(clamping: outputDelta),
                cacheReadTokens: Int(clamping: cacheReadDelta),
                cacheWriteTokens: Int(clamping: cacheWriteDelta),
                rawCostUSD: costDelta > 0 ? costDelta : nil
            ))
        }
        return records
    }

    private static let hasAnyLedgerUsage =
        "(input_tokens IS NOT NULL OR output_tokens IS NOT NULL OR total_tokens IS NOT NULL OR cache_read_tokens IS NOT NULL OR cache_write_tokens IS NOT NULL)"

    private static func baselineTimestamp(for session: SessionUsage) -> Date {
        if let timestamp = session.ledger.timestamp { return Date(timeIntervalSince1970: Double(timestamp)) }
        if let created = session.createdAt { return Date(timeIntervalSince1970: Double(created)) }
        if let updated = session.updatedAt { return Date(timeIntervalSince1970: Double(updated)) }
        return safeBaselineTimestamp
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
    private static func positiveInt64(_ value: String?) -> Int64? {
        guard let value, let number = Int64(value), number > 0 else { return nil }
        return number
    }
    private static func double(_ value: String?) -> Double { Double(value ?? "") ?? 0 }
    private static func string(_ value: String?) -> String { value ?? "" }

    private static func lastError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func adapterError(code: Int32, message: String) -> NSError {
        NSError(domain: "GooseAdapter", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
