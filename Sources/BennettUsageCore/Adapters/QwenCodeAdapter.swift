import Foundation

/// Adapter for Qwen Code (Alibaba's Gemini CLI fork).
///
/// Qwen Code keeps the Gemini CLI session layout under its own home directory
/// (`QWEN_DIR = ".qwen"`, overridable via `QWEN_HOME`): chats stream to
/// `~/.qwen/tmp/<projectHash>/chats/session-*.jsonl` with a legacy
/// single-blob `session-*.json` variant. Per-message token summaries follow
/// the same `TokensSummary` shape (`{input, output, cached, thoughts?, tool?,
/// total}`, where `input` already includes `cached`).
///
/// The parser mirrors `GeminiAdapter` semantics: incremental byte-offset
/// sync, metadata re-read for appended session context, and
/// content-addressed record ids (`qwen_<sessionId>_<messageId>`) so
/// re-emission deduplicates via INSERT OR IGNORE.
public struct QwenCodeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "qwen"
    public let displayName: String = "Qwen Code"
    public let brandColorHex: String = "#615CED"
    public let sfSymbolIcon: String = "cloud.fill"
    public let defaultPath: String = "~/.qwen"

    public init() {}

    public func detectDefaultPath() -> URL? {
        // QWEN_HOME relocates the whole runtime directory.
        if let home = ProcessInfo.processInfo.environment["QWEN_HOME"], !home.isEmpty {
            let url = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let tokensKey = Data("\"tokens\"".utf8)
    private static let messagesKey = Data("\"messages\"".utf8)
    private static let sessionIdKey = Data("\"sessionId\"".utf8)
    private static let directoriesKey = Data("\"directories\"".utf8)

    static func isUUIDSessionFileName(_ stem: String) -> Bool {
        guard stem.count >= 32 && stem.count <= 36 else { return false }
        return stem.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) || $0 == 0x2D
        }
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var previousOffsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            previousOffsets = dict
        }
        var offsets = previousOffsets
        var records: [UnifiedTokenRecord] = []

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()
        var seenPaths = Set<String>()
        while let fileUrl = enumerator?.nextObject() as? URL {
            let fileName = fileUrl.lastPathComponent
            guard (fileName.hasPrefix("session-") || (fileName.count >= 32 && fileUrl.pathExtension == "jsonl")), fileUrl.pathExtension == "jsonl" || fileUrl.pathExtension == "json" else { continue }

            let path = fileUrl.path
            seenPaths.insert(path)
            let resourceValues = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            if fileSize > 0, fileSize == (previousOffsets[path] ?? -1) { continue }

            if fileUrl.pathExtension == "json" {
                guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
                    offsets.removeValue(forKey: path)
                    continue
                }
                var sessionId = fileUrl.deletingPathExtension().lastPathComponent
                var projectFolder: String?
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let sid = root["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
                    if let dirs = root["directories"] as? [String], let first = dirs.first, !first.isEmpty {
                        projectFolder = first
                    }
                    let messages = root["messages"] as? [[String: Any]] ?? []
                    for (i, message) in messages.enumerated() {
                        if let record = Self.makeRecord(
                            message, fallbackIndex: i, sessionId: sessionId,
                            projectFolder: projectFolder, sourceId: sourceId,
                            isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                            records.append(record)
                        }
                    }
                }
                offsets[path] = fileSize
                continue
            }

            if let parsedOffset = previousOffsets["\(path)::off"], fileSize >= parsedOffset,
               let context = Self.readFirstLineContext(of: fileUrl) {
                var sessionId = fileUrl.deletingPathExtension().lastPathComponent
                var projectFolder: String?
                if let sid = context.sessionId, !sid.isEmpty { sessionId = sid }
                if let dir = context.directories, !dir.isEmpty { projectFolder = dir }

                if let chunk = Self.readAppendix(from: fileUrl, at: parsedOffset, expectingBytes: fileSize - parsedOffset) {
                    if let lastNewline = chunk.lastIndex(of: 0x0A) {
                        let completeEnd = chunk.index(after: lastNewline)
                        let baseLines = Int(previousOffsets["\(path)::lines"] ?? 0)
                        let parsed = Self.parseJSONLLines(
                            chunk[..<completeEnd],
                            startLineIndex: baseLines,
                            sessionId: sessionId,
                            projectFolder: projectFolder,
                            sourceId: sourceId,
                            isoFormatter: isoFormatter,
                            fallbackIso: fallbackIso,
                            into: &records
                        )
                        offsets[path] = fileSize
                        offsets["\(path)::off"] = parsedOffset + Int64(completeEnd)
                        offsets["\(path)::lines"] = Int64(baseLines + parsed.lines)
                    } else {
                        offsets[path] = fileSize
                    }
                    continue
                }
            }

            guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
                Self.dropCursor(&offsets, path: path)
                continue
            }
            var lineCount = 0
            var parsedEnd = 0
            if let lastNewline = data.lastIndex(of: 0x0A) {
                parsedEnd = data.index(after: lastNewline)
                let parsed = Self.parseJSONLLines(
                    data[..<parsedEnd],
                    startLineIndex: 0,
                    sessionId: fileUrl.deletingPathExtension().lastPathComponent,
                    projectFolder: nil,
                    sourceId: sourceId,
                    isoFormatter: isoFormatter,
                    fallbackIso: fallbackIso,
                    into: &records
                )
                lineCount = parsed.lines
            }

            offsets[path] = fileSize
            offsets["\(path)::off"] = Int64(parsedEnd)
            offsets["\(path)::lines"] = Int64(lineCount)
        }

        offsets = offsets.filter { key, _ in
            if let range = key.range(of: "::", options: .backwards) {
                return seenPaths.contains(String(key[..<range.lowerBound]))
            }
            return seenPaths.contains(key)
        }
        return (records, .fileOffsets(offsets))
    }

    // MARK: - Line parsing (Gemini/Qwen TokensSummary shape)

    private static func parseJSONLLines(
        _ data: Data,
        startLineIndex: Int,
        sessionId: String,
        projectFolder: String?,
        sourceId: String,
        isoFormatter: ISO8601DateFormatter,
        fallbackIso: ISO8601DateFormatter,
        into records: inout [UnifiedTokenRecord]
    ) -> (lines: Int, appended: Int) {
        var lines = 0
        var appended = 0
        var currentSessionId = sessionId
        var currentProject = projectFolder
        var searchRange = data.startIndex..<data.endIndex
        while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
            let lineData = data[searchRange.lowerBound..<newlineIndex]
            searchRange = data.index(after: newlineIndex)..<data.endIndex
            let lineIndex = startLineIndex + lines
            lines += 1
            guard !lineData.isEmpty else { continue }
            guard lineData.range(of: tokensKey) != nil
                || lineData.range(of: messagesKey) != nil
                || lineData.range(of: sessionIdKey) != nil
                || lineData.range(of: directoriesKey) != nil else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if json["$rewindTo"] != nil || json["$set"] != nil { continue }
            if let sid = json["sessionId"] as? String, !sid.isEmpty { currentSessionId = sid }
            if let dirs = json["directories"] as? [String], let first = dirs.first, !first.isEmpty {
                currentProject = first
            }
            if let messages = json["messages"] as? [[String: Any]] {
                // Metadata record still carrying a full message snapshot.
                for (i, message) in messages.enumerated() {
                    if let record = makeRecord(
                        message, fallbackIndex: lineIndex + i, sessionId: currentSessionId,
                        projectFolder: currentProject, sourceId: sourceId,
                        isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                        records.append(record)
                        appended += 1
                    }
                }
                continue
            }
            if let message = json["message"] as? [String: Any] {
                if let record = makeRecord(
                    message, fallbackIndex: lineIndex, sessionId: currentSessionId,
                    projectFolder: currentProject, sourceId: sourceId,
                    isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                    records.append(record)
                    appended += 1
                }
                continue
            }
            if json["tokens"] != nil {
                if let record = makeRecord(
                    json, fallbackIndex: lineIndex, sessionId: currentSessionId,
                    projectFolder: currentProject, sourceId: sourceId,
                    isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                    records.append(record)
                    appended += 1
                }
            }
        }
        return (lines, appended)
    }

    private static func makeRecord(
        _ message: [String: Any],
        fallbackIndex: Int,
        sessionId: String,
        projectFolder: String?,
        sourceId: String,
        isoFormatter: ISO8601DateFormatter,
        fallbackIso: ISO8601DateFormatter
    ) -> UnifiedTokenRecord? {
        guard (message["type"] as? String) == "gemini" || message["tokens"] != nil else { return nil }
        let tokens = (message["tokens"] as? [String: Any]) ?? [:]
        let input = intValue(tokens["input"])
        let output = intValue(tokens["output"])
        let cached = intValue(tokens["cached"])
        let thoughts = intValue(tokens["thoughts"])
        let tool = intValue(tokens["tool"])
        guard input + output + cached + thoughts + tool > 0 else { return nil }

        let messageId = (message["id"] as? String) ?? "offset_\(fallbackIndex)"
        var timestamp = Date()
        if let tsStr = message["timestamp"] as? String {
            timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
        }
        return UnifiedTokenRecord(
            id: "qwen_\(sessionId)_\(messageId)",
            sourceId: sourceId,
            timestamp: timestamp,
            sessionKey: sessionId,
            projectFolder: projectFolder,
            model: (message["model"] as? String) ?? "qwen",
            provider: "qwen",
            // input already includes cached (promptTokenCount semantics).
            inputTokens: max(0, input - cached),
            outputTokens: output + thoughts + tool,
            cacheReadTokens: cached,
            cacheWriteTokens: 0
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    private static func readFirstLineContext(of fileUrl: URL) -> (sessionId: String?, directories: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65536), !data.isEmpty else { return nil }
        let end = data.firstIndex(of: 0x0A) ?? data.endIndex
        guard let json = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any] else {
            return (nil, nil)
        }
        let sid = json["sessionId"] as? String
        let dir = (json["directories"] as? [String])?.first
        return (sid, dir)
    }

    private static func readAppendix(from fileUrl: URL, at offset: Int64, expectingBytes: Int64) -> Data? {
        guard expectingBytes > 0, expectingBytes < 256 * 1024 * 1024 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return data
    }

    private static func dropCursor(_ offsets: inout [String: Int64], path: String) {
        offsets.removeValue(forKey: path)
        offsets.removeValue(forKey: "\(path)::off")
        offsets.removeValue(forKey: "\(path)::lines")
    }
}
