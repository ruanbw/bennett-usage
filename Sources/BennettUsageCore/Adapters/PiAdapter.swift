import Foundation

public struct PiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "pi"
    public let displayName: String = "Pi Agent"
    public let brandColorHex: String = "#10B981"
    public let sfSymbolIcon: String = "sparkle"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.pi/agent/sessions" as NSString).expandingTildeInPath
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
        let enumerator = fileManager.enumerator(at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "jsonl" else { continue }
            let filePath = fileUrl.path
            let lastOffset = offsets[filePath] ?? 0

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }

            let fileSize = (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
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
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let usage = json["usage"] as? [String: Any] else {
                    continue
                }

                let promptTokens = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_write_tokens"] as? Int ?? 0

                let model = json["model"] as? String ?? "unknown"
                var timestamp = Date()
                if let tsStr = json["timestamp"] as? String {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                }

                let recordId = "pi_\(fileUrl.deletingPathExtension().lastPathComponent)_\(currentOffset)"
                let record = UnifiedTokenRecord(
                    id: recordId,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: fileUrl.lastPathComponent,
                    projectFolder: decodedProject,
                    model: model,
                    provider: nil,
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    rawCostUSD: nil
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
