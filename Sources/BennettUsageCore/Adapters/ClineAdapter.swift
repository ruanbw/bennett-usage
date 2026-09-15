import Foundation

/// Adapter for Cline's standalone runtime (desktop app / `cline` CLI), which
/// keeps its own store under `~/.cline` and is *not* covered by
/// `RooCodeAdapter` (that one reads the VSCode extension family's
/// `globalStorage/<publisher>/tasks` history).
///
/// Layout (https://docs.cline.bot/getting-started/config):
/// ```
/// ~/.cline/
///   data/sessions/<sessionId>/<sessionId>.messages.json   canonical transcript
///   data/sessions/<sessionId>/<sessionId>.json            session manifest
///   apps/<app>/sessions/<sessionId>.jsonl                 per-app event stream
/// ```
/// The transcript is the canonical usage artifact: every assistant message
/// carries `modelInfo` (`id`, `provider`) and `metrics` (`inputTokens`,
/// `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`), one entry per
/// provider round-trip. Message ids are stable, so the record id
/// `cline_<sessionId>_<messageId>` stays put while the file is rewritten
/// wholesale on every save (unchanged sizes are skipped via the cursor, and
/// re-parsed snapshots are dropped by the database's `INSERT OR IGNORE`).
///
/// The session manifest repeats the same numbers as one accumulated
/// `metadata.usage` object; it is used *only* for sessions without a
/// transcript file, so a transcript that shows up later can never be counted
/// again on top of the aggregate.
///
/// The per-app JSONL stream mirrors the same sessions, so it is parsed only
/// for session ids with no directory in the canonical store; byte offsets keep
/// re-reads idempotent.
///
/// `CLINE_SESSION_DATA_DIR`, `CLINE_DATA_DIR` and `CLINE_DIR` relocate the
/// store, mirroring the runtime's own precedence.
public struct ClineAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "cline"
    public let displayName: String = "Cline"
    public let brandColorHex: String = "#06B6D4"
    public let sfSymbolIcon: String = "hammer.fill"
    public let defaultPath: String = "~/.cline/data/sessions"

    public init() {}

    // MARK: - Roots

    private static func expanded(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func environment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// `<cline dir>`: `CLINE_DIR` wins, else `~/.cline`.
    static func clineRoot() -> URL {
        if let dir = environment("CLINE_DIR") { return expanded(dir) }
        return expanded("~/.cline")
    }

    /// `<cline dir>/data`: `CLINE_DATA_DIR` wins.
    static func dataRoot() -> URL {
        if let dir = environment("CLINE_DATA_DIR") { return expanded(dir) }
        return clineRoot().appendingPathComponent("data")
    }

    /// Canonical session store: `CLINE_SESSION_DATA_DIR` wins.
    static func sessionsRoot() -> URL {
        if let dir = environment("CLINE_SESSION_DATA_DIR") { return expanded(dir) }
        return dataRoot().appendingPathComponent("sessions")
    }

    /// `apps/<app>/sessions` directories next to `directory` (the canonical
    /// `<cline dir>/data/sessions`), so the stream fallback works for
    /// relocated stores too. Derived from the scanned root, never from the
    /// environment, which keeps callers (and tests) hermetic.
    static func appStreamRoots(relativeTo directory: URL) -> [URL] {
        let apps = directory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("apps")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: apps, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.map { $0.appendingPathComponent("sessions") }
    }

    public func detectDefaultPath() -> URL? {
        let root = Self.sessionsRoot()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root
    }

    // MARK: - Fetch

    /// Fast-reject key: only assistant messages carrying a `metrics` object
    /// produce records, so a transcript without it skips the full parse.
    private static let metricsKey = Data("\"metrics\"".utf8)
    /// Marker for the only stream event that carries token counts.
    private static let chatUsageMarker = Data("\"chat_usage\"".utf8)

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
        var seenPaths = Set<String>()
        var coveredSessions = Set<String>()
        let fileManager = FileManager.default

        // 1) Canonical per-session store: transcript first, manifest fallback.
        let sessionDirs = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        for sessionDir in sessionDirs {
            guard (try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sessionId = sessionDir.lastPathComponent
            coveredSessions.insert(sessionId)

            // File names mirror the session id, but stay tolerant of build
            // differences by picking by suffix.
            let contents = (try? fileManager.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])) ?? []
            var transcript: URL?
            var manifest: URL?
            for file in contents {
                let name = file.lastPathComponent
                if name.hasSuffix(".messages.json") {
                    transcript = file
                } else if name.hasSuffix(".json") {
                    manifest = manifest ?? file
                }
            }

            if let transcript {
                let path = transcript.path
                seenPaths.insert(path)
                let size = Int64((try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size != (previousOffsets[path] ?? -1) else { continue }
                offsets[path] = size
                guard let data = fileManager.contents(atPath: path), !data.isEmpty,
                      data.range(of: Self.metricsKey) != nil else { continue }
                let context = Self.sessionContext(manifestUrl: manifest)
                records.append(contentsOf: Self.parseTranscript(
                    data, sessionId: sessionId, sourceId: sourceId, context: context))
            } else if let manifest {
                let path = manifest.path
                seenPaths.insert(path)
                let size = Int64((try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size != (previousOffsets[path] ?? -1) else { continue }
                offsets[path] = size
                guard let data = fileManager.contents(atPath: path), !data.isEmpty else { continue }
                let context = Self.sessionContext(manifestData: data)
                if let aggregate = context.aggregate,
                   aggregate.input + aggregate.output + aggregate.cacheRead + aggregate.cacheWrite > 0 {
                    records.append(UnifiedTokenRecord(
                        id: "cline_\(sessionId)_aggregate",
                        sourceId: sourceId,
                        timestamp: context.startedAt ?? Date(),
                        sessionKey: sessionId,
                        projectFolder: context.projectFolder,
                        model: context.model,
                        provider: context.provider,
                        inputTokens: aggregate.input,
                        outputTokens: aggregate.output,
                        cacheReadTokens: aggregate.cacheRead,
                        cacheWriteTokens: aggregate.cacheWrite
                    ))
                }
            }
        }

        // 2) Per-app event streams, only for sessions the canonical store does
        // not know about (the same session appears in both).
        for root in Self.appStreamRoots(relativeTo: directory) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                guard !coveredSessions.contains(sessionId) else { continue }
                let path = file.path
                seenPaths.insert(path)
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var startOffset = previousOffsets[path] ?? 0
                if size < startOffset { startOffset = 0 }  // truncated or replaced
                guard size > startOffset else { continue }
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(startOffset))
                guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
                let (parsed, consumed) = Self.parseUsageStream(
                    data, sessionId: sessionId, sourceId: sourceId, startOffset: startOffset)
                records.append(contentsOf: parsed)
                offsets[path] = consumed
            }
        }

        offsets = offsets.filter { seenPaths.contains($0.key) }
        return (records, .fileOffsets(offsets))
    }

    // MARK: - Transcript

    /// Session-level defaults shared by the transcript and aggregate paths.
    struct SessionContext {
        var model: String = "unknown"
        var provider: String?
        var projectFolder: String?
        var startedAt: Date?
        var aggregate: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)?
    }

    static func sessionContext(manifestUrl: URL?) -> SessionContext {
        guard let url = manifestUrl,
              let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else {
            return SessionContext()
        }
        return sessionContext(manifestData: data)
    }

    static func sessionContext(manifestData: Data) -> SessionContext {
        var context = SessionContext()
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            return context
        }
        let metadata = manifest["metadata"] as? [String: Any] ?? [:]
        if let model = (manifest["model"] as? String) ?? (metadata["model"] as? String), !model.isEmpty {
            context.model = model
        }
        context.provider = (manifest["provider"] as? String) ?? (metadata["provider"] as? String)
        context.startedAt = parseTimestamp(manifest["started_at"] ?? manifest["updated_at"])
        context.projectFolder = projectFolder(
            workspaceRoot: manifest["workspace_root"] as? String,
            cwd: manifest["cwd"] as? String)
        // `usage` is this session alone; `aggregateUsage` folds in subagents,
        // which have their own session directories and would be double counted.
        if let usage = (metadata["usage"] as? [String: Any]) ?? (manifest["usage"] as? [String: Any]) {
            context.aggregate = (
                input: intValue(usage["inputTokens"] ?? usage["input_tokens"]),
                output: intValue(usage["outputTokens"] ?? usage["output_tokens"]),
                cacheRead: intValue(usage["cacheReadTokens"] ?? usage["cache_read_tokens"]),
                cacheWrite: intValue(usage["cacheWriteTokens"] ?? usage["cache_write_tokens"])
            )
        }
        return context
    }

    /// One record per assistant message carrying `metrics`. The canonical
    /// artifact is an object with a `messages` array; a bare array is
    /// tolerated for forward/backward compatibility.
    static func parseTranscript(
        _ data: Data,
        sessionId: String,
        sourceId: String,
        context: SessionContext
    ) -> [UnifiedTokenRecord] {
        let entries: [[String: Any]]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = (object["messages"] as? [[String: Any]]) ?? []
        } else if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = array
        } else {
            return []
        }
        guard !entries.isEmpty else { return [] }

        var records: [UnifiedTokenRecord] = []
        for (index, entry) in entries.enumerated() {
            guard let metrics = entry["metrics"] as? [String: Any] else { continue }
            let input = intValue(metrics["inputTokens"] ?? metrics["input_tokens"])
            let output = intValue(metrics["outputTokens"] ?? metrics["output_tokens"])
            let cacheWrite = intValue(metrics["cacheWriteTokens"] ?? metrics["cache_write_tokens"])
            let cacheRead = intValue(metrics["cacheReadTokens"] ?? metrics["cache_read_tokens"])
            guard input + output + cacheWrite + cacheRead > 0 else { continue }

            let modelInfo = entry["modelInfo"] as? [String: Any]
            let model = (modelInfo?["id"] as? String)
                ?? (entry["model"] as? String)
                ?? context.model
            let provider = (modelInfo?["provider"] as? String) ?? context.provider
            let messageId = (entry["id"] as? String) ?? "idx\(index)"
            let cost = doubleValue(metrics["cost"] ?? metrics["totalCost"])
            records.append(UnifiedTokenRecord(
                id: "cline_\(sessionId)_\(messageId)",
                sourceId: sourceId,
                timestamp: parseTimestamp(entry["ts"] ?? entry["timestamp"]) ?? context.startedAt ?? Date(),
                sessionKey: sessionId,
                projectFolder: context.projectFolder,
                model: model,
                provider: provider,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                rawCostUSD: cost > 0 ? cost : nil
            ))
        }
        return records
    }

    // MARK: - Event stream

    /// Parses `chat_usage` events out of an app stream. Values are already
    /// per-request (`totalInputTokens`/`totalOutputTokens` are the running
    /// sums and are deliberately ignored). Only complete lines are consumed,
    /// so a line still being appended is picked up on the next pass; the byte
    /// offset after each event keeps record ids stable across re-reads.
    static func parseUsageStream(
        _ data: Data,
        sessionId: String,
        sourceId: String,
        startOffset: Int64
    ) -> ([UnifiedTokenRecord], Int64) {
        var currentOffset = startOffset
        var records: [UnifiedTokenRecord] = []
        var searchRange = data.startIndex..<data.endIndex

        while let newline = data[searchRange].firstIndex(of: 0x0A) {
            let lineData = data[searchRange.lowerBound..<newline]
            searchRange = data.index(after: newline)..<data.endIndex
            currentOffset += Int64(lineData.count + 1)

            guard !lineData.isEmpty, lineData.range(of: Self.chatUsageMarker) != nil else { continue }
            guard let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (event["stream"] as? String) == "chat_usage",
                  let chunk = event["chunk"] as? String,
                  let chunkData = chunk.data(using: .utf8),
                  let usage = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                continue
            }

            let input = intValue(usage["inputTokens"] ?? usage["input_tokens"])
            let output = intValue(usage["outputTokens"] ?? usage["output_tokens"])
            let cacheWrite = intValue(usage["cacheWriteTokens"] ?? usage["cache_write_tokens"])
            let cacheRead = intValue(usage["cacheReadTokens"] ?? usage["cache_read_tokens"])
            guard input + output + cacheWrite + cacheRead > 0 else { continue }

            let cost = doubleValue(usage["cost"] ?? usage["totalCost"])
            records.append(UnifiedTokenRecord(
                id: "cline_\(sessionId)_req_\(currentOffset)",
                sourceId: sourceId,
                timestamp: parseTimestamp(event["ts"]) ?? Date(),
                sessionKey: sessionId,
                projectFolder: nil,
                model: "unknown",
                provider: nil,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                rawCostUSD: cost > 0 ? cost : nil
            ))
        }
        return (records, currentOffset)
    }

    // MARK: - Value helpers

    /// Workspace of the session. `workspace_root` wins over `cwd`; a bare "/"
    /// (sessions started without a project) counts as "no project" rather than
    /// flooding the project ranking with the filesystem root.
    static func projectFolder(workspaceRoot: String?, cwd: String?) -> String? {
        for candidate in [workspaceRoot, cwd] {
            guard var path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty, path != "/" else { continue }
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    /// Cline stamps epoch milliseconds (`ts`), ISO-8601 strings (`started_at`)
    /// and epoch seconds depending on the field.
    static func parseTimestamp(_ value: Any?) -> Date? {
        // Order matters: `Double`/`Int` bridge to `NSNumber`, so testing for
        // `NSNumber` first would recurse forever.
        if let d = value as? Double { return date(fromEpoch: d) }
        if let i = value as? Int { return date(fromEpoch: Double(i)) }
        if let n = value as? NSNumber { return date(fromEpoch: n.doubleValue) }
        if let s = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            if let ms = Double(s) { return date(fromEpoch: ms) }
        }
        return nil
    }

    private static func date(fromEpoch value: Double) -> Date? {
        if value > 1_000_000_000_000 { return Date(timeIntervalSince1970: value / 1000.0) }
        if value > 1_000_000_000 { return Date(timeIntervalSince1970: value) }
        return nil
    }
}
