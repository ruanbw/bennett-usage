import Foundation

/// Adapter for the VSCode extension agent family: Roo Code, Cline and Kilo Code.
///
/// All three persist per-task history under VSCode's extension global
/// storage:
/// `…/Code/User/globalStorage/<publisher>/tasks/<taskId>/api_conversation_history.json`
/// (`rooveterinaryinc.roo-cline`, `saoudrizwan.claude-dev`, `kilocode.kilo-code`;
/// Cursor/VSCodium/Insiders hosts carry the same publishers under their own
/// `Application Support` roots and are scanned too).
///
/// Each history file is a JSON array; token-bearing entries carry `tokensIn`,
/// `tokensOut`, `cacheWrites`, `cacheReads` (plus `ts` in epoch ms and the
/// `modelId` on some builds). Record ids
/// (`roo_<taskId>_<index>`) are stable across reparses; unchanged files are
/// skipped by size, and task directories that vanish drop their cursor keys.
public struct RooCodeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "roo"
    public let displayName: String = "Roo Code · Cline"
    public let brandColorHex: String = "#7C3AED"
    public let sfSymbolIcon: String = "square.stack.3d.up.fill"
    public let defaultPath: String = "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"

    /// Extension publishers covered by this adapter, in preference order.
    static let publishers = [
        "rooveterinaryinc.roo-cline",
        "saoudrizwan.claude-dev",
        "kilocode.kilo-code",
    ]

    /// Host application support roots that may host the publishers above.
    static let hostRoots = [
        "~/Library/Application Support/Code/User/globalStorage",
        "~/Library/Application Support/Cursor/User/globalStorage",
        "~/Library/Application Support/Code - Insiders/User/globalStorage",
        "~/Library/Application Support/VSCodium/User/globalStorage",
        "~/.config/Code/User/globalStorage",
        "~/.config/Cursor/User/globalStorage",
    ]

    public init() {}

    public func detectDefaultPath() -> URL? {
        for root in Self.taskRoots() {
            if FileManager.default.fileExists(atPath: root.path) { return root }
        }
        return nil
    }

    static func taskRoots() -> [URL] {
        var roots: [URL] = []
        for host in hostRoots {
            let base = (host as NSString).expandingTildeInPath
            for publisher in publishers {
                roots.append(URL(fileURLWithPath: base)
                    .appendingPathComponent(publisher)
                    .appendingPathComponent("tasks"))
            }
        }
        return roots
    }

    /// Fast-reject keys: only lines/entries mentioning token counts are parsed.
    private static let tokensInKey = Data("tokensIn".utf8)
    private static let inputTokensKey = Data("input_tokens".utf8)
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

        // The coordinator passes one watched root; scan it plus every other
        // known tasks root so a single adapter covers the whole family even
        // when only the first existing root is watched.
        var roots = [directory]
        for root in Self.taskRoots() where root.path != directory.path {
            roots.append(root)
        }

        let fileManager = FileManager.default
        var seenPaths = Set<String>()
        for root in roots {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            // Each task is a directory containing api_conversation_history.json.
            guard let taskDirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for taskDir in taskDirs {
                let historyUrl = taskDir.appendingPathComponent("api_conversation_history.json")
                guard fileManager.fileExists(atPath: historyUrl.path) else { continue }
                let path = historyUrl.path
                seenPaths.insert(path)
                let fileSize = Int64((try? historyUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if fileSize > 0, fileSize == (previousOffsets[path] ?? -1) { continue }
                guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
                    offsets[path] = fileSize
                    continue
                }
                // Cheap pre-scan before paying for full JSON parsing.
                guard data.range(of: Data("tokensIn".utf8)) != nil ||
                      data.range(of: Data("input_tokens".utf8)) != nil ||
                      data.range(of: Data("\"usage\"".utf8)) != nil else {
                    offsets[path] = fileSize
                    continue
                }
                let taskId = taskDir.lastPathComponent
                let parsed = Self.parseHistory(
                    data, taskId: taskId, taskDir: taskDir, sourceId: sourceId)
                records.append(contentsOf: parsed)
                offsets[path] = fileSize
            }
        }

        offsets = offsets.filter { seenPaths.contains($0.key) }
        return (records, .fileOffsets(offsets))
    }

    static func parseHistory(
        _ data: Data,
        taskId: String,
        taskDir: URL,
        sourceId: String
    ) -> [UnifiedTokenRecord] {
        // History files are arrays; tolerate a wrapping object just in case.
        var entries: [[String: Any]] = []
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = array
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = (obj["messages"] as? [[String: Any]])
                ?? (obj["history"] as? [[String: Any]])
                ?? []
        }
        guard !entries.isEmpty else { return [] }

        //Task-level fallbacks: model + project + start time.
        var fallbackModel = "roo"
        var projectFolder: String?
        let fm = FileManager.default
        if let metaData = fm.contents(atPath: taskDir.appendingPathComponent("task_metadata.json").path),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            fallbackModel = (meta["modelId"] as? String)
                ?? (meta["model"] as? String)
                ?? fallbackModel
            projectFolder = (meta["project"] as? String)
                ?? (meta["workspace"] as? String)
                ?? (meta["cwd"] as? String)
        }
        if projectFolder == nil,
           let uiData = fm.contents(atPath: taskDir.appendingPathComponent("ui_messages.json").path) {
            func extractFolder(from dict: [String: Any]) -> String? {
                if let p = (dict["project"] as? String) ?? (dict["workspace"] as? String) ?? (dict["cwd"] as? String), !p.isEmpty {
                    return p
                }
                return nil
            }
            if let ui = try? JSONSerialization.jsonObject(with: uiData) as? [String: Any] {
                projectFolder = extractFolder(from: ui)
            } else if let uiArray = try? JSONSerialization.jsonObject(with: uiData) as? [[String: Any]] {
                if let first = uiArray.first, let p = extractFolder(from: first) {
                    projectFolder = p
                } else if let last = uiArray.last, let p = extractFolder(from: last) {
                    projectFolder = p
                } else {
                    for msg in uiArray {
                        if let p = extractFolder(from: msg) {
                            projectFolder = p
                            break
                        }
                    }
                }
            }
        }

        var records: [UnifiedTokenRecord] = []
        for (index, entry) in entries.enumerated() {
            let usage = (entry["usage"] as? [String: Any]) ?? (entry["tokens"] as? [String: Any]) ?? entry
            let input = intValue(usage["tokensIn"] ?? usage["tokens_in"]
                ?? usage["input_tokens"] ?? usage["inputTokens"])
            let output = intValue(usage["tokensOut"] ?? usage["tokens_out"]
                ?? usage["output_tokens"] ?? usage["outputTokens"])
            let cacheWrite = intValue(usage["cacheWrites"] ?? usage["cache_writes"]
                ?? usage["cache_creation_input_tokens"] ?? usage["cacheWriteTokens"])
            let cacheRead = intValue(usage["cacheReads"] ?? usage["cache_reads"]
                ?? usage["cache_read_input_tokens"] ?? usage["cacheReadTokens"])
            guard input + output + cacheWrite + cacheRead > 0 else { continue }

            let model = (entry["modelId"] as? String)
                ?? (entry["model"] as? String)
                ?? (usage["modelId"] as? String)
                ?? (usage["model"] as? String)
                ?? fallbackModel
            let timestamp = parseTimestamp(entry["ts"] ?? entry["timestamp"] ?? usage["ts"] ?? usage["timestamp"])
            records.append(UnifiedTokenRecord(
                id: "roo_\(taskId)_\(index)",
                sourceId: sourceId,
                timestamp: timestamp,
                sessionKey: taskId,
                projectFolder: projectFolder,
                model: model,
                provider: nil,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            ))
        }
        return records
    }

    static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    static func parseTimestamp(_ value: Any?) -> Date {
        if let ms = value as? Double {
            if ms > 1_000_000_000_000 { return Date(timeIntervalSince1970: ms / 1000.0) }
            if ms > 1_000_000_000 { return Date(timeIntervalSince1970: ms) }
            return Date()
        }
        if let n = value as? NSNumber { return parseTimestamp(n.doubleValue) }
        if let i = value as? Int { return parseTimestamp(Double(i)) }
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
        }
        return Date()
    }
}
