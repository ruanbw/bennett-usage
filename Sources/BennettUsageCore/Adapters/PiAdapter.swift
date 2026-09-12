import Foundation

public struct PiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "pi"
    public let displayName: String = "Pi Agent"
    public let brandColorHex: String = "#10B981"
    public let sfSymbolIcon: String = "sparkle"
    public let defaultPath: String = "~/.pi/agent/sessions"

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
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            offsets = dict
        }

        var records: [UnifiedTokenRecord] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "jsonl" else { continue }
            let filePath = fileUrl.path
            let lastOffset = offsets[filePath] ?? 0

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }

            let fileSize = Int64((try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fileSize <= lastOffset { continue }

            try handle.seek(toOffset: UInt64(lastOffset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            let folderName = fileUrl.deletingLastPathComponent().lastPathComponent
            let decodedProject = decodeProjectFolder(folderName)

            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex

            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                currentOffset += Int64(lineData.count + 1)

                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                let message = json["message"] as? [String: Any]
                guard let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) else {
                    continue
                }

                let promptTokens = (usage["input"] as? Int)
                    ?? (usage["prompt_tokens"] as? Int)
                    ?? (usage["input_tokens"] as? Int)
                    ?? ((usage["input"] as? NSNumber)?.intValue)
                    ?? ((usage["prompt_tokens"] as? NSNumber)?.intValue)
                    ?? ((usage["input_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let completionTokens = (usage["output"] as? Int)
                    ?? (usage["completion_tokens"] as? Int)
                    ?? (usage["output_tokens"] as? Int)
                    ?? ((usage["output"] as? NSNumber)?.intValue)
                    ?? ((usage["completion_tokens"] as? NSNumber)?.intValue)
                    ?? ((usage["output_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let cacheRead = (usage["cacheRead"] as? Int)
                    ?? (usage["cache_read_tokens"] as? Int)
                    ?? ((usage["cacheRead"] as? NSNumber)?.intValue)
                    ?? ((usage["cache_read_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let cacheWrite = (usage["cacheWrite"] as? Int)
                    ?? (usage["cache_write_tokens"] as? Int)
                    ?? ((usage["cacheWrite"] as? NSNumber)?.intValue)
                    ?? ((usage["cache_write_tokens"] as? NSNumber)?.intValue)
                    ?? 0

                let rawCost: Double?
                if let costDict = usage["cost"] as? [String: Any] {
                    if let d = costDict["total"] as? Double {
                        rawCost = d
                    } else if let num = costDict["total"] as? NSNumber {
                        rawCost = num.doubleValue
                    } else {
                        rawCost = nil
                    }
                } else if let costVal = usage["cost"] as? Double {
                    rawCost = costVal
                } else if let num = usage["cost"] as? NSNumber {
                    rawCost = num.doubleValue
                } else {
                    rawCost = nil
                }

                let model = (message?["model"] as? String)
                    ?? (json["model"] as? String)
                    ?? "unknown"

                var timestamp = Date()
                if let tsStr = (json["timestamp"] as? String) ?? (message?["timestamp"] as? String) {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                }

                let projectFolder: String?
                if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                    projectFolder = cwd
                } else {
                    projectFolder = decodedProject
                }

                let recordId = "pi_\(fileUrl.deletingLastPathComponent().lastPathComponent)_\(fileUrl.deletingPathExtension().lastPathComponent)_\(currentOffset)"
                let record = UnifiedTokenRecord(
                    id: recordId,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: fileUrl.lastPathComponent,
                    projectFolder: projectFolder,
                    model: model,
                    provider: nil,
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    rawCostUSD: rawCost
                )
                records.append(record)
            }

            offsets[filePath] = currentOffset
        }

        return (records, .fileOffsets(offsets))
    }

    private func decodeProjectFolder(_ folderName: String) -> String? {
        guard folderName.hasPrefix("--") && folderName.hasSuffix("--") else { return nil }
        let trimmed = folderName.dropFirst(2).dropLast(2)
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }
}
