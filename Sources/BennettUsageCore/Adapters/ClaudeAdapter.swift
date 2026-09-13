import Foundation

/// Adapter for Claude Code session transcripts.
///
/// Claude Code appends one JSON object per line to
/// `~/.claude/projects/<dash-munged-cwd>/<session-uuid>.jsonl`
/// (subagent threads live in sibling `subagents/agent-*.jsonl` files, which
/// the recursive enumeration picks up automatically).
///
/// An `assistant` line nests the raw Anthropic API response under `message`:
/// `message.id`, `message.model` and `message.usage` (`input_tokens`,
/// `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`).
/// One API turn is fanned out into several consecutive assistant lines (one
/// per streamed content block) that all repeat the same `usage` object, so
/// lines are deduplicated by `message.id` (last wins) — naive per-line
/// summation overcounts by the block fan-out factor.
///
/// Record ids are content-addressed (`claude_<messageId>`), making
/// re-emission idempotent via INSERT OR IGNORE. The byte-offset cursor only
/// avoids re-reading unchanged files; truncation (compaction rewrites) falls
/// back to a full reparse, which still deduplicates.
public struct ClaudeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "claude"
    public let displayName: String = "Claude Code"
    public let brandColorHex: String = "#D97706"
    public let sfSymbolIcon: String = "brain.head.profile"
    public let defaultPath: String = "~/.claude"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fast-reject keys: only `assistant` lines carrying a `usage` object can
    /// yield a record; everything else skips JSON parsing.
    private static let assistantKey = Data("\"assistant\"".utf8)
    private static let usageKey = Data("\"usage\"".utf8)

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
        // message.id -> record index in `records`, for within-pass fan-out
        // dedupe (last streamed block wins).
        var seenMessageIds: [String: Int] = [:]

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
            // Compaction can rewrite a transcript shorter; reparse from zero
            // (content-addressed ids keep it idempotent).
            if fileSize < lastOffset { lastOffset = 0 }
            if fileSize <= lastOffset { continue }

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: UInt64(lastOffset)) } catch { continue }
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            // Project fallback from the munged folder name (`-Users-you-app`
            // -> `/Users/you/app`); per-line `cwd` takes precedence.
            let folderName = fileUrl.deletingLastPathComponent().lastPathComponent
            let decodedProject = Self.decodeProjectFolder(folderName)

            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex
            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                currentOffset += Int64(lineData.count + 1)
                guard !lineData.isEmpty else { continue }
                guard lineData.range(of: Self.assistantKey) != nil,
                      lineData.range(of: Self.usageKey) != nil else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (json["type"] as? String) == "assistant",
                      let message = json["message"] as? [String: Any],
                      let messageId = message["id"] as? String, !messageId.isEmpty,
                      let usage = message["usage"] as? [String: Any] else { continue }

                let input = Self.intValue(usage["input_tokens"])
                let output = Self.intValue(usage["output_tokens"])
                let cacheRead = Self.intValue(usage["cache_read_input_tokens"])
                let cacheWrite = Self.intValue(usage["cache_creation_input_tokens"])
                guard input + output + cacheRead + cacheWrite > 0 else { continue }

                let model = (message["model"] as? String) ?? "claude"
                var timestamp = Date()
                if let tsStr = json["timestamp"] as? String {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                }
                let projectFolder: String?
                if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                    projectFolder = cwd
                } else {
                    projectFolder = decodedProject
                }
                let sessionKey: String
                if let sid = json["sessionId"] as? String, !sid.isEmpty {
                    sessionKey = sid
                } else {
                    sessionKey = fileUrl.deletingPathExtension().lastPathComponent
                }

                let record = UnifiedTokenRecord(
                    id: "claude_\(messageId)",
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: sessionKey,
                    projectFolder: projectFolder,
                    model: model,
                    provider: "anthropic",
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite
                )
                if let existing = seenMessageIds[messageId] {
                    records[existing] = record
                } else {
                    seenMessageIds[messageId] = records.count
                    records.append(record)
                }
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

    private static func decodeProjectFolder(_ folderName: String) -> String? {
        // `~/.claude/projects/-Users-you-code-app`: leading dash marks the
        // absolute-path root; remaining dashes are `/` separators.
        guard folderName.hasPrefix("-") else { return nil }
        let decoded = "/" + folderName.dropFirst().replacingOccurrences(of: "-", with: "/")
        return DatabaseManager.canonicalProjectFolder(decoded)
    }
}
