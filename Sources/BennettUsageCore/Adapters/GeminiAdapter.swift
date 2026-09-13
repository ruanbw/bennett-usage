import Foundation

/// Adapter for Gemini CLI session recordings.
///
/// Reads `~/.gemini/tmp/<projectHash>/chats/session-*.jsonl` (JSONL streaming
/// format) and legacy `session-*.json` (single ConversationRecord). Per-message
/// token summaries follow the official `TokensSummary` shape:
/// `{input, output, cached, thoughts?, tool?, total}` where `input` is the raw
/// `promptTokenCount` and already includes `cached` (`cachedContentTokenCount`).
///
/// Subsequent syncs only parse bytes appended after the last complete
/// (newline-terminated) line; on every incremental pass the leading metadata
/// record (`sessionId`, `directories`) is re-read so appended messages keep
/// their session context. Record ids are content-addressed
/// (`gemini_<sessionId>_<messageId>`), making re-emission idempotent — the
/// database deduplicates via INSERT OR IGNORE.
public struct GeminiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "gemini"
    public let displayName: String = "Gemini CLI"
    public let brandColorHex: String = "#4285F4"
    public let sfSymbolIcon: String = "diamond.fill"
    public let defaultPath: String = "~/.gemini"

    public init() {}

    /// ASCII bytes of the keys that can make a JSONL line worth parsing. A
    /// line can only yield a token record when it carries a `tokens` object
    /// (or a `messages` snapshot of them), and only lines carrying
    /// `sessionId`/`directories` update the session context, so a cheap byte
    /// scan lets metadata markers (`$rewindTo`/`$set`) and tool-call lines
    /// skip the JSONSerialization + bridging pass entirely.
    private static let tokensKey = Data("\"tokens\"".utf8)
    private static let messagesKey = Data("\"messages\"".utf8)
    private static let sessionIdKey = Data("\"sessionId\"".utf8)
    private static let directoriesKey = Data("\"directories\"".utf8)

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var previousOffsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            previousOffsets = dict
        }
        // Start from the previous cursor so unchanged files keep their entries.
        // Per-file keys:
        //   "<path>"        — file size (unchanged-file fast path)
        //   "<path>::off"   — byte offset just past the last parsed complete line
        //   "<path>::lines" — number of complete lines already parsed (keeps the
        //                     "offset_<n>" fallback ids stable across parses)
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
            guard fileName.hasPrefix("session-"),
                  fileUrl.pathExtension == "jsonl" || fileUrl.pathExtension == "json"
            else { continue }

            let path = fileUrl.path
            seenPaths.insert(path)
            // One resourceValues call serves both the regular-file check and
            // the size fast path (the enumerator prefetched the same keys,
            // so this is cache-served, not a fresh stat per key).
            let resourceValues = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            // Skip session files unchanged since the last sync: their records
            // are already in the database (content-addressed ids dedupe).
            if fileSize > 0, fileSize == (previousOffsets[path] ?? -1) { continue }

            if fileUrl.pathExtension == "json" {
                // Legacy format: one ConversationRecord JSON blob per file,
                // always re-parsed in full when it changes.
                guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
                    dropCursor(&offsets, path: path)
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
                        if let record = makeRecord(message, fallbackIndex: i, sessionId: sessionId,
                                                   projectFolder: projectFolder,
                                                   isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                            records.append(record)
                        }
                    }
                }
                offsets[path] = fileSize
                continue
            }

            // Streaming JSONL. Incremental pass when a parsed byte offset is
            // known and the file has only grown: read and parse just the
            // appended complete lines.
            if let parsedOffset = previousOffsets["\(path)::off"], fileSize >= parsedOffset,
               let context = readFirstLineContext(of: fileUrl) {
                var sessionId = fileUrl.deletingPathExtension().lastPathComponent
                var projectFolder: String?
                if let sid = context.sessionId, !sid.isEmpty { sessionId = sid }
                if let dir = context.directories, !dir.isEmpty { projectFolder = dir }

                if let chunk = readAppendix(from: fileUrl, at: parsedOffset, expectingBytes: fileSize - parsedOffset) {
                    // Only complete (newline-terminated) lines are parsed; a
                    // partially written trailing line is picked up once its
                    // newline arrives.
                    if let lastNewline = chunk.lastIndex(of: 0x0A) {
                        // Slice through the trailing newline so the final
                        // appended line is newline-terminated and parsed.
                        let completeEnd = chunk.index(after: lastNewline)
                        let baseLines = Int(previousOffsets["\(path)::lines"] ?? 0)
                        let parsed = parseJSONLLines(
                            chunk[..<completeEnd],
                            startLineIndex: baseLines,
                            sessionId: sessionId,
                            projectFolder: projectFolder,
                            isoFormatter: isoFormatter,
                            fallbackIso: fallbackIso,
                            into: &records
                        )
                        offsets[path] = fileSize
                        offsets["\(path)::off"] = parsedOffset + Int64(completeEnd)
                        offsets["\(path)::lines"] = Int64(baseLines + parsed.lines)
                    } else {
                        // Appended bytes contain no complete line yet.
                        offsets[path] = fileSize
                    }
                    continue
                }
            }

            // Full (re)parse: first sighting, legacy cursor, shrunk file, or
            // any incremental failure.
            guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
                dropCursor(&offsets, path: path)
                continue
            }
            var lineCount = 0
            var parsedEnd = 0
            if let lastNewline = data.lastIndex(of: 0x0A) {
                parsedEnd = data.index(after: lastNewline)
                let parsed = parseJSONLLines(
                    data[..<parsedEnd],
                    startLineIndex: 0,
                    sessionId: fileUrl.deletingPathExtension().lastPathComponent,
                    projectFolder: nil,
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

        // Drop cursor entries for session files that no longer exist.
        offsets = offsets.filter { key, _ in
            if let range = key.range(of: "::", options: .backwards) {
                return seenPaths.contains(String(key[..<range.lowerBound]))
            }
            return seenPaths.contains(key)
        }

        return (records, .fileOffsets(offsets))
    }

    // MARK: - JSONL helpers

    /// Builds a token record from one Gemini message entry; nil for entries
    /// without token data.
    private func makeRecord(
        _ message: [String: Any],
        fallbackIndex: Int,
        sessionId: String,
        projectFolder: String?,
        isoFormatter: ISO8601DateFormatter,
        fallbackIso: ISO8601DateFormatter
    ) -> UnifiedTokenRecord? {
        guard (message["type"] as? String) == "gemini",
              let tokens = message["tokens"] as? [String: Any]
        else { return nil }

        let number = { (key: String) -> Int in
            (tokens[key] as? NSNumber)?.intValue ?? 0
        }
        let rawInput = number("input")
        let cached = number("cached")
        let output = number("output")
        let thoughts = number("thoughts")

        var timestamp = Date()
        if let tsStr = message["timestamp"] as? String {
            timestamp = isoFormatter.date(from: tsStr)
                ?? fallbackIso.date(from: tsStr)
                ?? Date()
        }

        let messageId = (message["id"] as? String)
            // Fallback must be stable across sync runs (records are
            // re-emitted and deduplicated by id), so derive it from the
            // position within this file, not from the global record count.
            ?? "offset_\(fallbackIndex)"
        return UnifiedTokenRecord(
            id: "gemini_\(sessionId)_\(messageId)",
            sourceId: sourceId,
            timestamp: timestamp,
            sessionKey: sessionId,
            projectFolder: projectFolder,
            model: (message["model"] as? String) ?? "gemini",
            provider: "google",
            // promptTokenCount includes cachedContentTokenCount; avoid double counting.
            inputTokens: max(0, rawInput - cached),
            outputTokens: output + thoughts,
            cacheReadTokens: cached,
            cacheWriteTokens: 0,
            rawCostUSD: nil
        )
    }

    /// Parses complete JSONL lines (each ending at a newline) and appends
    /// token records. `startLineIndex` is the absolute 0-based index of the
    /// first line in the file so `offset_<n>` fallback ids stay stable across
    /// incremental parses. Returns the number of lines processed and the
    /// final session context.
    private func parseJSONLLines(
        _ data: Data,
        startLineIndex: Int,
        sessionId: String,
        projectFolder: String?,
        isoFormatter: ISO8601DateFormatter,
        fallbackIso: ISO8601DateFormatter,
        into records: inout [UnifiedTokenRecord]
    ) -> (lines: Int, sessionId: String, projectFolder: String?) {
        var sessionId = sessionId
        var projectFolder = projectFolder
        var lineIndex = startLineIndex

        var searchRange = data.startIndex..<data.endIndex
        while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
            let lineData = data[searchRange.lowerBound..<newlineIndex]
            searchRange = data.index(after: newlineIndex)..<data.endIndex
            defer { lineIndex += 1 }

            guard !lineData.isEmpty else { continue }
            // Fast reject: a line can only change the output when it carries
            // token data, a message snapshot, or session context. Markers and
            // tool-call lines skip the JSON parse + bridging pass entirely.
            guard lineData.range(of: Self.tokensKey) != nil
                || lineData.range(of: Self.messagesKey) != nil
                || lineData.range(of: Self.sessionIdKey) != nil
                || lineData.range(of: Self.directoriesKey) != nil
            else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if json["$rewindTo"] != nil || json["$set"] != nil { continue }
            if let sid = json["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
            if let dirs = json["directories"] as? [String], let first = dirs.first, !first.isEmpty {
                projectFolder = first
            }

            if let messages = json["messages"] as? [[String: Any]] {
                // Metadata record still carrying a full message snapshot.
                for (i, message) in messages.enumerated() {
                    if let record = makeRecord(message, fallbackIndex: lineIndex + i,
                                               sessionId: sessionId, projectFolder: projectFolder,
                                               isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                        records.append(record)
                    }
                }
            } else if let record = makeRecord(json, fallbackIndex: lineIndex,
                                              sessionId: sessionId, projectFolder: projectFolder,
                                              isoFormatter: isoFormatter, fallbackIso: fallbackIso) {
                records.append(record)
            }
        }

        return (lineIndex - startLineIndex, sessionId, projectFolder)
    }

    /// Reads the first (metadata) JSONL line to recover the session context
    /// for incremental parses. Returns nil when the file cannot be opened,
    /// the head is empty, or the first line is missing or not a valid JSON
    /// object — the caller then falls back to a full re-parse.
    private func readFirstLineContext(of url: URL) -> (sessionId: String?, directories: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard !head.isEmpty, let newline = head.firstIndex(of: 0x0A) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: head[..<newline]) as? [String: Any]
        else { return nil }
        return (json["sessionId"] as? String, (json["directories"] as? [String])?.first)
    }

    /// Reads the file bytes at/after `offset`. Returns nil when the file
    /// cannot be opened, seeked, or short-reads the expected bytes — the
    /// caller then falls back to a full re-parse.
    private func readAppendix(from url: URL, at offset: Int64, expectingBytes: Int64) -> Data? {
        guard expectingBytes >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        let chunk = handle.readDataToEndOfFile()
        // A short read means the file changed underneath us — reparse in full.
        guard Int64(chunk.count) >= expectingBytes else { return nil }
        return chunk
    }

    /// Forgets a file's cursor entries so the next sync re-parses it in full.
    private func dropCursor(_ offsets: inout [String: Int64], path: String) {
        offsets.removeValue(forKey: path)
        offsets.removeValue(forKey: "\(path)::off")
        offsets.removeValue(forKey: "\(path)::lines")
    }
}
