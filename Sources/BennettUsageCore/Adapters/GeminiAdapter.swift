import Foundation

/// Adapter for Gemini CLI session recordings.
///
/// Reads `~/.gemini/tmp/<projectHash>/chats/session-*.jsonl` (JSONL streaming
/// format) and legacy `session-*.json` (single ConversationRecord). Per-message
/// token summaries follow the official `TokensSummary` shape:
/// `{input, output, cached, thoughts?, tool?, total}` where `input` is the raw
/// `promptTokenCount` and already includes `cached` (`cachedContentTokenCount`).
///
/// Files are always re-parsed from the start so the leading metadata record
/// (`sessionId`, `directories`) is available for appended messages. Record ids
/// are content-addressed (`gemini_<sessionId>_<messageId>`), making re-emission
/// idempotent — the database deduplicates via INSERT OR IGNORE.
public struct GeminiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "gemini"
    public let displayName: String = "Gemini CLI"
    public let brandColorHex: String = "#4285F4"
    public let sfSymbolIcon: String = "diamond.fill"
    public let defaultPath: String = "~/.gemini"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var records: [UnifiedTokenRecord] = []
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            offsets = dict
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: rootDirectory, includingPropertiesForKeys: [.isRegularFileKey])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        while let fileUrl = enumerator?.nextObject() as? URL {
            let fileName = fileUrl.lastPathComponent
            guard fileName.hasPrefix("session-"),
                  fileUrl.pathExtension == "jsonl" || fileUrl.pathExtension == "json",
                  (try? fileUrl.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }

            guard let data = fileManager.contents(atPath: fileUrl.path), !data.isEmpty else { continue }
            // Session-scoped context carried across JSONL records.
            var sessionId = fileUrl.deletingPathExtension().lastPathComponent
            var projectFolder: String?

            func processMessage(_ message: [String: Any], fallbackIndex: Int) {
                guard (message["type"] as? String) == "gemini",
                      let tokens = message["tokens"] as? [String: Any]
                else { return }

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
                let record = UnifiedTokenRecord(
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
                records.append(record)
            }

            if fileUrl.pathExtension == "json" {
                // Legacy format: one ConversationRecord JSON blob per file.
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let sid = root["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
                    if let dirs = root["directories"] as? [String], let first = dirs.first, !first.isEmpty {
                        projectFolder = first
                    }
                    let messages = root["messages"] as? [[String: Any]] ?? []
                    for (i, message) in messages.enumerated() {
                        processMessage(message, fallbackIndex: i)
                    }
                }
            } else {
                // Streaming JSONL: metadata record first, then per-message records.
                var searchRange = data.startIndex..<data.endIndex
                var lineIndex = 0
                while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                    let lineData = data[searchRange.lowerBound..<newlineIndex]
                    searchRange = data.index(after: newlineIndex)..<data.endIndex
                    defer { lineIndex += 1 }

                    guard !lineData.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                    else { continue }

                    if json["$rewindTo"] != nil || json["$set"] != nil { continue }
                    if let sid = json["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
                    if let dirs = json["directories"] as? [String], let first = dirs.first, !first.isEmpty {
                        projectFolder = first
                    }

                    if let messages = json["messages"] as? [[String: Any]] {
                        // Metadata record still carrying a full message snapshot.
                        for (i, message) in messages.enumerated() {
                            processMessage(message, fallbackIndex: lineIndex + i)
                        }
                    } else {
                        processMessage(json, fallbackIndex: lineIndex)
                    }
                }
            }

            offsets[fileUrl.path] = Int64(data.count)
        }

        return (records, .fileOffsets(offsets))
    }
}
