import Foundation

public struct PiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "pi"
    public let displayName: String = "Pi Agent"
    public let brandColorHex: String = "#10B981"
    public let sfSymbolIcon: String = "sparkle"
    public let defaultPath: String = "~/.pi/agent/sessions"

    public init() {}

    /// ASCII bytes of the `"usage"` key. Every token-bearing JSONL line
    /// contains it, so a cheap byte scan lets non-usage lines (reasoning,
    /// tool calls, headers) skip the JSON parse + NSNumber bridging pass.
    private static let usageKey = Data("\"usage\"".utf8)

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A `.jsonl` transcript that may hold new usage.
    private struct TranscriptCandidate {
        let url: URL
        /// Stable cursor key for this transcript. See `transcriptKey(for:)`.
        let key: String
        /// Size already fetched by a directory enumerator, or `nil` when the file
        /// was handed over directly by an event and still needs one `stat`.
        let prefetchedSize: Int64?
    }

    /// Stable dictionary key for a transcript.
    ///
    /// A directory enumeration hands back `/private/var/...` while FSEvents — and
    /// therefore `changedPaths` — describes the same file as `/var/...`. Keying
    /// the cursor by the raw spelling made an event-scoped pass miss the offset
    /// the previous full sweep recorded and re-read the whole file. Resolving
    /// symlinks converges the two spellings, and leaves ordinary paths such as
    /// `~/.pi/...` byte-identical so already-stored cursors keep matching.
    private static func transcriptKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Visits the transcripts this pass has to read.
    ///
    /// A full sweep (`changedPaths == nil`) still enumerates the tree. An
    /// event-scoped pass reads only what FSEvents reported: `~/.pi/agent/sessions`
    /// holds thousands of entries, so re-walking it to pick up one appended
    /// transcript was the dominant cost of every sync pass.
    private static func forEachTranscript(
        under rootDirectory: URL,
        changedPaths: [String]?,
        _ visit: (TranscriptCandidate) throws -> Void
    ) rethrows {
        var seen = Set<String>()
        guard let changedPaths, !changedPaths.isEmpty else {
            try visitEnumeratedTranscripts(under: rootDirectory, seen: &seen, visit)
            return
        }

        let rootKey = transcriptKey(for: rootDirectory)
        for rawPath in changedPaths {
            let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            let key = transcriptKey(for: url)
            // FSEvents also reports parents of a watch root; only paths inside
            // this root belong to this adapter.
            guard key == rootKey || key.hasPrefix(rootKey + "/") else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // A directory-level event — a session directory created, renamed
                // or removed — still needs its own subtree read.
                try visitEnumeratedTranscripts(under: url, seen: &seen, visit)
            } else if (key as NSString).pathExtension == "jsonl", seen.insert(key).inserted {
                try visit(TranscriptCandidate(url: url, key: key, prefetchedSize: nil))
            }
        }
    }

    private static func visitEnumeratedTranscripts(
        under directory: URL,
        seen: inout Set<String>,
        _ visit: (TranscriptCandidate) throws -> Void
    ) rethrows {
        // Only `.fileSizeKey` is read below. Prefetching
        // `.contentModificationDateKey`/`.isRegularFileKey` as well made the
        // enumerator fetch metadata per entry that this adapter never reads.
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let key = transcriptKey(for: url)
            guard seen.insert(key).inserted else { continue }
            // Served from the enumerator's prefetch cache.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            try visit(TranscriptCandidate(url: url, key: key, prefetchedSize: size.map { Int64($0) }))
        }
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await fetchIncrementalRecords(from: rootDirectory, since: cursor, changedPaths: nil)
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?,
        changedPaths: [String]?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            offsets = dict
        }

        var records: [UnifiedTokenRecord] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        try Self.forEachTranscript(under: rootDirectory, changedPaths: changedPaths) { candidate in
            let fileUrl = candidate.url
            let fileSize = candidate.prefetchedSize
                ?? Int64((try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // A session transcript can be compacted or rewritten shorter. Without
            // this fallback the file was never read again (`fileSize <= lastOffset`),
            // so its usage stayed permanently short — and if it later grew past
            // the stale offset, parsing resumed mid-line and attributed the rest
            // to the wrong records. Claude, Codex and Cline all re-read from zero
            // here for the same reason.
            let previousOffset = offsets[candidate.key] ?? 0
            let lastOffset = fileSize < previousOffset ? 0 : previousOffset
            guard fileSize > lastOffset else { return }

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { return }
            defer { try? handle.close() }

            try handle.seek(toOffset: UInt64(lastOffset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

            let folderName = fileUrl.deletingLastPathComponent().lastPathComponent
            let decodedProject = decodeProjectFolder(folderName)

            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex

            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                currentOffset += Int64(lineData.count + 1)

                guard !lineData.isEmpty else { continue }
                // Fast reject: a record is only produced when a `usage`
                // object is present, so lines lacking the key can skip the
                // expensive JSONSerialization + bridging pass entirely.
                guard lineData.range(of: Self.usageKey) != nil else { continue }
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

            offsets[candidate.key] = currentOffset
        }

        return (records, .fileOffsets(offsets))
    }

    private func decodeProjectFolder(_ folderName: String) -> String? {
        guard folderName.hasPrefix("--") && folderName.hasSuffix("--") else { return nil }
        let trimmed = folderName.dropFirst(2).dropLast(2)
        // The encoding turns every "/" into "-", so original "-" inside a
        // component (e.g. "trove-rag", UUIDs) is ambiguous and a naive decode
        // splits it. The per-line `cwd` already takes precedence; this
        // fallback only runs when `cwd` is absent, so resolve greedily
        // against the filesystem (longest existing hyphen-group wins) and
        // keep the naive decode when nothing matches.
        return DatabaseManager.canonicalProjectFolder("/" + trimmed.replacingOccurrences(of: "-", with: "/"))
    }
}
