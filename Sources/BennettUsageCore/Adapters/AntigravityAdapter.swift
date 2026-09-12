import Foundation
import SQLite3

/// Adapter for Antigravity (Google's agentic IDE).
///
/// Antigravity stores one SQLite database per conversation under
/// `~/.gemini/antigravity/conversations/<conversation-uuid>.db`. Token usage
/// lives in the `steps` table: rows with `step_type = 15` are model responses
/// and their `metadata` BLOB is a protobuf message carrying
///   - field 1: creation timestamp `{ seconds: 1, nanos: 2 }`
///   - field 9: per-request usage `{ 2: uncached prompt, 3: output tokens,
///     5: cached prompt }` where field 3 already includes thinking tokens
///     (it equals the sum of the response/thoughts breakdown in fields 9/10).
///
/// Prompt totals grow monotonically as `field2 + field5`, matching Gemini's
/// `promptTokenCount` semantics with implicit context caching, so:
/// `inputTokens = field2`, `cacheReadTokens = field5`, `outputTokens = field3`.
///
/// The `gen_metadata` table holds one row per model request (aligned 1:1 with
/// the `step_type = 15` steps in `idx` order); field 1 → 19 is the model name.
///
/// Record ids are content-addressed (`antigravity_<conversation>_<stepIdx>`)
/// so refetches deduplicate via INSERT OR IGNORE.
public struct AntigravityAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "antigravity"
    public let displayName: String = "Antigravity"
    public let brandColorHex: String = "#EA4335"
    public let sfSymbolIcon: String = "triangle.fill"
    public let defaultPath: String = "~/.gemini/antigravity/conversations"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var records: [UnifiedTokenRecord] = []
        var offsets: [String: Int64] = [:]

        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []

        for dbUrl in contents where dbUrl.pathExtension == "db" {
            guard (try? dbUrl.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let size = (try? dbUrl.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            offsets[dbUrl.path] = Int64(size)

            // READONLY can fail against a WAL database with a stale -shm and no
            // live writer (SQLite cannot recover the WAL without write access).
            // Retry with READWRITE — only SELECTs run; the sole "write" is the
            // WAL recovery any SQLite client performs on such databases.
            let parsed = parseConversationDB(at: dbUrl, openReadOnly: true)
                ?? parseConversationDB(at: dbUrl, openReadOnly: false)
            guard let parsed else { continue }
            records.append(contentsOf: parsed)
        }

        return (records, .fileOffsets(offsets))
    }

    // MARK: - Conversation database parsing

    private func parseConversationDB(at dbUrl: URL, openReadOnly: Bool) -> [UnifiedTokenRecord]? {
        let flags = SQLITE_OPEN_FULLMUTEX | (openReadOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbUrl.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let conversationId = dbUrl.deletingPathExtension().lastPathComponent

        // gen_metadata rows pair 1:1 (by idx order) with step_type=15 steps.
        var models: [String] = []
        var modelStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx ASC", -1, &modelStmt, nil) == SQLITE_OK {
            while sqlite3_step(modelStmt) == SQLITE_ROW {
                models.append(Self.modelName(fromBlob: sqlite3_column_blob(modelStmt, 0),
                                            size: Int(sqlite3_column_bytes(modelStmt, 0))))
            }
            sqlite3_finalize(modelStmt)
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT idx, metadata FROM steps WHERE step_type = 15 ORDER BY idx ASC",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var records: [UnifiedTokenRecord] = []
        var modelIndex = 0

        var stepFailed = false

        while true {
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else {
                stepFailed = (rc != SQLITE_DONE)
                break
            }

            defer { modelIndex += 1 }

            let stepIdx = sqlite3_column_int64(stmt, 0)
            let metadata = sqlite3_column_blob(stmt, 1)
            let metadataSize = Int(sqlite3_column_bytes(stmt, 1))

            guard let data = metadata.flatMap({ Data(bytes: $0, count: metadataSize) }), !data.isEmpty,
                  let usage = Self.stepUsage(from: data)
            else { continue }

            let model = modelIndex < models.count ? models[modelIndex] : nil

            let record = UnifiedTokenRecord(
                id: "antigravity_\(conversationId)_\(stepIdx)",
                sourceId: sourceId,
                timestamp: usage.timestamp,
                sessionKey: conversationId,
                projectFolder: nil,
                model: model ?? "gemini",
                provider: "google",
                inputTokens: usage.input,
                outputTokens: usage.output,
                cacheReadTokens: usage.cacheRead,
                cacheWriteTokens: 0,
                rawCostUSD: nil
            )
            records.append(record)
        }

        // A mid-loop error (e.g. SQLITE_BUSY, readonly WAL recovery failure)
        // makes the record set incomplete — signal the caller to retry.
        if stepFailed { return nil }
        return records
    }

    // MARK: - Protobuf decoding

    private struct PBField {
        let number: Int
        let varint: UInt64?
        let bytes: Data?
    }

    /// Decodes a protobuf message into its top-level fields; nil if malformed.
    private static func protobufFields(in data: Data) -> [PBField]? {
        let bytes = [UInt8](data)
        var fields: [PBField] = []
        var i = 0

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift <= 63 else { return nil }
                let byte = bytes[i]
                i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        while i < bytes.count {
            guard let key = readVarint() else { return nil }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)
            guard number > 0 else { return nil }
            switch wireType {
            case 0:
                guard let value = readVarint() else { return nil }
                fields.append(PBField(number: number, varint: value, bytes: nil))
            case 2:
                guard let length = readVarint(), i + Int(length) <= bytes.count else { return nil }
                fields.append(PBField(number: number, varint: nil, bytes: Data(bytes[i..<i + Int(length)])))
                i += Int(length)
            case 5:
                guard i + 4 <= bytes.count else { return nil }
                i += 4
            case 1:
                guard i + 8 <= bytes.count else { return nil }
                i += 8
            default:
                return nil
            }
        }
        return fields
    }

    private static func firstBytesField(_ number: Int, in fields: [PBField]) -> Data? {
        fields.first { $0.number == number }?.bytes
    }

    private static func firstVarintField(_ number: Int, in fields: [PBField]) -> UInt64? {
        fields.first { $0.number == number }?.varint
    }

    private struct StepUsage {
        let timestamp: Date
        let input: Int
        let output: Int
        let cacheRead: Int
    }

    /// Extracts timestamp + usage from a `step_type = 15` metadata blob.
    private static func stepUsage(from metadata: Data) -> StepUsage? {
        guard let fields = protobufFields(in: metadata) else { return nil }

        var timestamp = Date()
        if let tsData = firstBytesField(1, in: fields),
           let tsFields = protobufFields(in: tsData),
           let seconds = firstVarintField(1, in: tsFields) {
            let nanos = firstVarintField(2, in: tsFields) ?? 0
            timestamp = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000.0)
        }

        guard let usageData = firstBytesField(9, in: fields),
              let usageFields = protobufFields(in: usageData)
        else { return nil }

        let input = Int(firstVarintField(2, in: usageFields) ?? 0)
        let output = Int(firstVarintField(3, in: usageFields) ?? 0)
        let cacheRead = Int(firstVarintField(5, in: usageFields) ?? 0)
        guard input > 0 || output > 0 || cacheRead > 0 else { return nil }

        return StepUsage(timestamp: timestamp, input: input, output: output, cacheRead: cacheRead)
    }

    /// Extracts the model name from a `gen_metadata` blob (field 1 → 19).
    private static func modelName(fromBlob blob: UnsafeRawPointer?, size: Int) -> String {
        guard let blob, size > 0 else { return "gemini" }
        let data = Data(bytes: blob, count: size)
        guard let fields = protobufFields(in: data),
              let wrapper = firstBytesField(1, in: fields),
              let wrapperFields = protobufFields(in: wrapper),
              let modelData = firstBytesField(19, in: wrapperFields),
              let name = String(data: modelData, encoding: .utf8), !name.isEmpty
        else { return "gemini" }
        return name
    }
}
