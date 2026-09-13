import Foundation

/// Adapter for OpenAI Codex CLI session logs.
///
/// Codex CLI writes per-session JSONL to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-uuid>.jsonl`.
/// Token usage arrives as `event_msg` lines whose payload is a `token_count`
/// event:
/// `payload.info.last_token_usage = { input_tokens, cached_input_tokens,
/// output_tokens, reasoning_output_tokens, total_tokens }` (incremental cost
/// of that turn) alongside `payload.info.total_token_usage` (session
/// cumulative — never summed). Following the OpenAI Responses semantics,
/// `input_tokens` already includes `cached_input_tokens`, and
/// `output_tokens` already includes `reasoning_output_tokens`, so the record
/// splits them instead of adding: `input = input_tokens - cached`,
/// `cacheRead = cached`, `output = output_tokens`.
///
/// Record ids (`codex_<fileStem>_<byteOffset>`) are stable across reparses;
/// the database deduplicates via INSERT OR IGNORE.
public struct CodexAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "codex"
    public let displayName: String = "OpenAI Codex"
    public let brandColorHex: String = "#10A37F"
    public let sfSymbolIcon: String = "chevron.left.forwardslash.chevron.right"
    public let defaultPath: String = "~/.codex"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fast-reject keys: only `token_count` events carry usage.
    private static let tokenCountKey = Data("token_count".utf8)
    private static let usageKey = Data("last_token_usage".utf8)

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var previousOffsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            previousOffsets = dict
        }
        var offsets = previousOffsets
        var records: [UnifiedTokenRecord] = []
        var lastTotalTokens: [String: Int] = [:]

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()
        var seenPaths = Set<String>()

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "jsonl" else { continue }
            let resourceValues = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let path = fileUrl.path
            seenPaths.insert(path)
            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            var lastOffset = previousOffsets[path] ?? 0
            if fileSize < lastOffset { lastOffset = 0 }
            if fileSize <= lastOffset { continue }

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: UInt64(lastOffset)) } catch { continue }
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            let fileStem = fileUrl.deletingPathExtension().lastPathComponent
            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex
            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                let lineOffset = currentOffset
                currentOffset += Int64(lineData.count + 1)
                guard !lineData.isEmpty else { continue }
                guard lineData.range(of: Self.tokenCountKey) != nil,
                      lineData.range(of: Self.usageKey) != nil else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (json["type"] as? String) == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { continue }

                let totalTokens = Self.intValue((info["total_token_usage"] as? [String: Any])?["total_tokens"])
                if totalTokens > 0 {
                    if let prev = lastTotalTokens[path], totalTokens <= prev {
                        // Pure rate-limit update rebroadcasting stale last_token_usage; skip.
                        continue
                    }
                    lastTotalTokens[path] = totalTokens
                }

                let inputTotal = Self.intValue(last["input_tokens"])
                let cached = Self.intValue(last["cached_input_tokens"])
                let output = Self.intValue(last["output_tokens"])
                guard inputTotal + output > 0 else { continue }

                let model = (payload["model"] as? String)
                    ?? (info["model"] as? String)
                    ?? "codex"
                var timestamp = Date()
                if let tsStr = json["timestamp"] as? String {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                }
                // Session id prefers the payload, then the rollout filename.
                let sessionKey: String
                if let sid = payload["id"] as? String, !sid.isEmpty {
                    sessionKey = sid
                } else if let meta = payload["meta"] as? [String: Any],
                          let sid = meta["id"] as? String, !sid.isEmpty {
                    sessionKey = sid
                } else {
                    sessionKey = fileStem
                }
                // Working directory is recorded on session_meta lines, not on
                // token events; recover what the filename offers (date
                // sharding carries no project), so leave project unset here.
                let record = UnifiedTokenRecord(
                    id: "codex_\(fileStem)_\(lineOffset)",
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: sessionKey,
                    projectFolder: nil,
                    model: model,
                    provider: "openai",
                    inputTokens: max(0, inputTotal - cached),
                    outputTokens: output,
                    cacheReadTokens: cached,
                    cacheWriteTokens: 0
                )
                records.append(record)
            }
            offsets[path] = currentOffset
        }

        offsets = offsets.filter { seenPaths.contains($0.key) }
        return (records, .fileOffsets(offsets))
    }

    private static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}
