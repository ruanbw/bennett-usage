import Foundation

/// Adapter for DSH (DeepSeek Harness) sessions.
///
/// Home resolution mirrors `@deepseek-ai/dsh-home-paths`: an explicit path
/// wins, then `$DSH_HOME`, then `~/.dsh`. Sessions live under
/// `<home>/sessions/<dash-munged-cwd>/<session-id>/session.v3.jsonl.zstd`
/// (one JSON object per line, zstd-compressed).
///
/// Primary path — transcript: every assistant settlement appends an
/// `assistant/message` line carrying `data.usage` in the canonical
/// token-meter buckets (`inputTokens` = uncached prompt input,
/// `outputTokens`, `cacheReadTokens`; `totalTokens` is their sum). Record ids
/// (`dsh_<sessionId>_<seq>`) are content-addressed on the stable per-session
/// `seq`, so the full reparse that follows any size change deduplicates via
/// INSERT OR IGNORE. Model/provider come from
/// `data.message.source.{model,provider}`; timestamps are the line `time`
/// (epoch ms); the project is the header line's `cwd`.
///
/// Swift has no system zstd decoder (`COMPRESSION_ZSTD` does not exist in the
/// SDK), so decompression shells out to a `zstd` CLI when one is installed.
/// Fallback path — projcache: `<home>/storages/session_projcache/sessions/`
/// `<session-id>.json` is plain JSON holding the same cumulative
/// `tokenUsage.totals`; the adapter emits the delta since the last sync as a
/// single record (`dsh_<sessionId>_cum_<totals>`, file mtime as timestamp).
/// The two paths use disjoint id/cursor namespaces; a mid-life switch between
/// them can double-count one window (documented, rare: installing/removing
/// `zstd` between syncs).
public struct DshAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "dsh"
    public let displayName: String = "DSH Harness"
    public let brandColorHex: String = "#4D6BFE"
    public let sfSymbolIcon: String = "cpu.fill"
    public let defaultPath: String = "~/.dsh"

    public init() {}

    /// Mirrors `resolveDshHome`: explicit override (unused here), then
    /// `$DSH_HOME` when non-blank, then `~/.dsh`.
    public static func resolveHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: ("~/.dsh" as NSString).expandingTildeInPath)
    }

    public func detectDefaultPath() -> URL? {
        let home = Self.resolveHome()
        let sessions = home.appendingPathComponent("sessions")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDir), isDir.boolValue {
            return sessions
        }
        if FileManager.default.fileExists(atPath: home.path) { return home }
        return nil
    }

    /// Fast-reject keys for transcript lines.
    private static let assistantMessageKey = Data("\"assistant/message\"".utf8)
    private static let usageKey = Data("\"usage\"".utf8)
    private static let sessionTypeKey = Data("\"session\"".utf8)

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

        let home = Self.homeDir(under: directory)
        let resolvedDefault = Self.resolveDefaultModel(home: home)
        let defaultModel = resolvedDefault?.model ?? "unknown"
        let defaultProvider = resolvedDefault?.provider ?? "unknown"
        let canDecompressZstd = Self.zstdExecutable() != nil

        let sessionsDir = Self.sessionsDir(under: directory)
        let fileManager = FileManager.default
        var transcriptSessionIds = Set<String>()
        if let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let fileUrl = enumerator.nextObject() as? URL {
            let name = fileUrl.lastPathComponent
            // Parentheses are load-bearing: a comma guard list parses
            // `A, B || C, D` as `A && (B || C) && D`.
            guard (name.hasPrefix("session") && name.hasSuffix(".jsonl.zstd"))
                || (name.hasPrefix("session") && name.hasSuffix(".jsonl")) else { continue }
            let resourceValues = try? fileUrl.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let path = fileUrl.path
            seenPaths.insert(path)

            let sid = fileUrl.deletingLastPathComponent().lastPathComponent
            let isZstd = name.hasSuffix(".jsonl.zstd")
            if !isZstd || canDecompressZstd {
                transcriptSessionIds.insert(sid)
            }

            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            if fileSize > 0, fileSize == (previousOffsets[path] ?? -1) { continue }
            if fileSize == 0 {
                offsets[path] = 0
                continue
            }
            guard let jsonl = Self.decompressedContents(of: fileUrl) else {
                // Incomplete or in-flight frame: leave offset untouched to retry next sync;
                // keep sid in transcriptSessionIds to avoid projcache duplicate deltas.
                continue
            }
            let folderName = fileUrl.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            let parsed = Self.parseTranscript(
                jsonl, mungedFolder: folderName, sourceId: sourceId,
                defaultModel: defaultModel, defaultProvider: defaultProvider)
            records.append(contentsOf: parsed)
            offsets[path] = fileSize
            }
        }

        // Projcache covers every session the transcript path did not: missing
        // or undecodable transcripts, plus cache entries with no transcript
        // file on disk. Successfully parsed sessions are excluded so their
        // steps are never double-counted by deltas.
        do {
            let fallback = try fetchProjcacheDeltas(
                under: directory, previousOffsets: &offsets, seenPaths: &seenPaths,
                excludingSessions: transcriptSessionIds,
                defaultModel: defaultModel, defaultProvider: defaultProvider)
            records.append(contentsOf: fallback)
        } catch {
            // A malformed cache file must not fail the whole adapter pass.
        }

        offsets = offsets.filter { key, _ in
            if key.hasSuffix("::cum-in") || key.hasSuffix("::cum-out")
                || key.hasSuffix("::cum-read") || key.hasSuffix("::cum-write") {
                return true
            }
            return seenPaths.contains(key)
        }
        return (records, .fileOffsets(offsets))
    }

    // MARK: - Paths

    static func sessionsDir(under directory: URL) -> URL {
        if directory.lastPathComponent == "sessions" { return directory }
        return directory.appendingPathComponent("sessions")
    }

    static func homeDir(under directory: URL) -> URL {
        // `directory` is either the home itself or the sessions dir inside it.
        if directory.lastPathComponent == "sessions" {
            return directory.deletingLastPathComponent()
        }
        return directory
    }

    // MARK: - Transcript path

    /// Locate a `zstd` CLI without assuming a fixed install prefix.
    static func zstdExecutable() -> URL? {
        for fixed in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"] {
            if FileManager.default.isExecutableFile(atPath: fixed) {
                return URL(fileURLWithPath: fixed)
            }
        }
        // PATH lookup via env(1), which always exists at a fixed path.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["zstd", "--version"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return nil }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    /// Decompress a transcript to raw JSONL. Plain `.jsonl` files are read
    /// directly; `.jsonl.zstd` goes through the CLI. Nil when undecodable.
    static func decompressedContents(of fileUrl: URL) -> Data? {
        if fileUrl.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: fileUrl), !data.isEmpty else { return nil }
            return data
        }
        let zstd: URL
        let args: [String]
        if let fixed = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            zstd = URL(fileURLWithPath: fixed)
            args = ["-d", "-c", "--", fileUrl.path]
        } else {
            zstd = URL(fileURLWithPath: "/usr/bin/env")
            args = ["zstd", "-d", "-c", "--", fileUrl.path]
            guard zstdExecutable() != nil else { return nil }
        }
        let process = Process()
        process.executableURL = zstd
        process.arguments = args
        // Stdout goes to a temp file, NOT a Pipe: transcripts decompress to
        // tens of MB, which would fill the 64KB pipe buffer while the parent
        // waits for exit — a classic deadlock that stalls each large session
        // until the deadline. A file lets the child stream unbounded.
        let tmpUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh_\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: tmpUrl.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmpUrl) }
        guard let outHandle = try? FileHandle(forWritingTo: tmpUrl) else { return nil }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            try? outHandle.close()
            return nil
        }
        // Bounded wait keeps a wedged child from stalling sync forever.
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try? outHandle.close()
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        guard let data = try? Data(contentsOf: tmpUrl), !data.isEmpty else { return nil }
        return data
    }

    /// Parse decompressed JSONL into per-step token records.
    static func parseTranscript(
        _ jsonl: Data,
        mungedFolder: String,
        sourceId: String,
        defaultModel: String = "unknown",
        defaultProvider: String = "unknown"
    ) -> [UnifiedTokenRecord] {
        var records: [UnifiedTokenRecord] = []
        var sessionId: String?
        var headerCwd: String?
        var headerCreatedAt: Date?

        var searchRange = jsonl.startIndex..<jsonl.endIndex
        while let newlineIndex = jsonl[searchRange].firstIndex(of: 0x0A) {
            let lineData = jsonl[searchRange.lowerBound..<newlineIndex]
            searchRange = jsonl.index(after: newlineIndex)..<jsonl.endIndex
            guard !lineData.isEmpty else { continue }
            // Header line first: establishes session context for everything
            // below (checked before the assistant fast-reject).
            if sessionId == nil, lineData.range(of: sessionTypeKey) != nil,
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               (json["type"] as? String) == "session" {
                sessionId = json["id"] as? String
                headerCwd = json["cwd"] as? String
                if let ms = (json["createdAt"] as? NSNumber)?.doubleValue {
                    headerCreatedAt = Date(timeIntervalSince1970: ms / 1000.0)
                }
                continue
            }
            guard lineData.range(of: assistantMessageKey) != nil,
                  lineData.range(of: usageKey) != nil else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "assistant/message",
                  let seq = (json["seq"] as? NSNumber)?.intValue,
                  let data = json["data"] as? [String: Any],
                  let usage = data["usage"] as? [String: Any] else { continue }

            let input = intValue(usage["inputTokens"] ?? usage["uncachedInputTokens"])
            let output = intValue(usage["outputTokens"])
            let cacheRead = intValue(usage["cacheReadTokens"])
            let cacheWrite = intValue(usage["cacheWriteTokens"])
            guard input + output + cacheRead + cacheWrite > 0 else { continue }

            let message = data["message"] as? [String: Any]
            let source = message?["source"] as? [String: Any]
            let model = (source?["model"] as? String) ?? defaultModel
            let provider = (source?["provider"] as? String) ?? defaultProvider

            var timestamp = headerCreatedAt ?? Date()
            if let ms = (json["time"] as? NSNumber)?.doubleValue {
                timestamp = Date(timeIntervalSince1970: ms / 1000.0)
            }
            let sid = sessionId ?? "unknown"
            records.append(UnifiedTokenRecord(
                id: "dsh_\(sid)_\(seq)",
                sourceId: sourceId,
                timestamp: timestamp,
                sessionKey: sid,
                projectFolder: headerCwd ?? decodeMungedFolder(mungedFolder),
                model: model,
                provider: provider,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            ))
        }
        return records
    }

    // MARK: - Projcache fallback path

    private func fetchProjcacheDeltas(
        under directory: URL,
        previousOffsets: inout [String: Int64],
        seenPaths: inout Set<String>,
        excludingSessions: Set<String> = [],
        defaultModel: String = "unknown",
        defaultProvider: String = "unknown"
    ) throws -> [UnifiedTokenRecord] {
        var records: [UnifiedTokenRecord] = []
        let cacheDir = Self.homeDir(under: directory)
            .appendingPathComponent("storages/session_projcache/sessions")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDir),
              isDir.boolValue,
              let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return records
        }
        for fileUrl in files where fileUrl.pathExtension == "json" {
            let sid = fileUrl.deletingPathExtension().lastPathComponent
            if excludingSessions.contains(sid) { continue }
            guard let data = try? Data(contentsOf: fileUrl),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = json["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let tokenUsage = rows["tokenUsage"] as? [String: Any],
                  let val = tokenUsage["val"] as? [String: Any],
                  let totals = val["totals"] as? [String: Any] else { continue }
            let totalIn = Self.intValue(totals["uncachedInputTokens"])
            let totalOut = Self.intValue(totals["outputTokens"])
            let totalRead = Self.intValue(totals["cacheReadTokens"])
            let totalWrite = Self.intValue(totals["cacheWriteTokens"])

            let keyBase = fileUrl.path
            let lastIn = previousOffsets[keyBase + "::cum-in"] ?? 0
            let lastOut = previousOffsets[keyBase + "::cum-out"] ?? 0
            let lastRead = previousOffsets[keyBase + "::cum-read"] ?? 0
            let lastWrite = previousOffsets[keyBase + "::cum-write"] ?? 0
            previousOffsets[keyBase + "::cum-in"] = Int64(totalIn)
            previousOffsets[keyBase + "::cum-out"] = Int64(totalOut)
            previousOffsets[keyBase + "::cum-read"] = Int64(totalRead)
            previousOffsets[keyBase + "::cum-write"] = Int64(totalWrite)

            let deltaIn = totalIn - Int(lastIn)
            let deltaOut = totalOut - Int(lastOut)
            let deltaRead = totalRead - Int(lastRead)
            let deltaWrite = totalWrite - Int(lastWrite)
            guard deltaIn + deltaOut + deltaRead + deltaWrite > 0 else { continue }

            var project: String?
            var createdAt = Date()
            if let identity = record["identity"] as? [String: Any] {
                project = identity["cwd"] as? String
                if let ms = (identity["createdAt"] as? NSNumber)?.doubleValue {
                    createdAt = Date(timeIntervalSince1970: ms / 1000.0)
                }
            }
            var model = defaultModel
            var provider = defaultProvider
            if let modelSelection = rows["modelSelection"] as? [String: Any],
               let mval = modelSelection["val"] as? [String: Any],
               let lastUsed = mval["lastUsed"] as? [String: Any] {
                if let m = lastUsed["model"] as? String, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model = m
                }
                if let p = lastUsed["provider"] as? String, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    provider = p
                }
            }

            // Attribute fresh usage to when the cache file says it happened.
            let mtime = (try? fileUrl.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            records.append(UnifiedTokenRecord(
                id: "dsh_\(sid)_cum_\(totalIn)_\(totalOut)_\(totalRead)_\(totalWrite)",
                sourceId: sourceId,
                timestamp: max(createdAt, mtime),
                sessionKey: sid,
                projectFolder: project,
                model: model,
                provider: provider,
                inputTokens: max(0, deltaIn),
                outputTokens: max(0, deltaOut),
                cacheReadTokens: max(0, deltaRead),
                cacheWriteTokens: max(0, deltaWrite)
            ))
        }
        return records
    }

    // MARK: - Helpers

    /// Resolves `agent-default-model` from `<home>/settings.yaml` when available.
    static func resolveDefaultModel(home: URL) -> (model: String, provider: String)? {
        let settingsUrl = home.appendingPathComponent("settings.yaml")
        guard let content = try? String(contentsOf: settingsUrl, encoding: .utf8) else { return nil }
        var inAgentDefaultModel = false
        var model: String?
        var provider: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("agent-default-model:") {
                inAgentDefaultModel = true
                continue
            }
            if inAgentDefaultModel {
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.contains(":") {
                    break
                }
                if trimmed.hasPrefix("model:") {
                    model = trimmed.dropFirst("model:".count).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("provider:") {
                    provider = trimmed.dropFirst("provider:".count).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let model = model, !model.isEmpty {
            return (model: model, provider: provider ?? "unknown")
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    /// `--Users-ruanbw-projects-x--` -> `/Users/ruanbw/projects/x`.
    static func decodeMungedFolder(_ folderName: String) -> String? {
        var name = folderName
        if name.hasPrefix("--"), name.hasSuffix("--"), name.count > 4 {
            name = String(name.dropFirst(2).dropLast(2))
        } else if name.hasPrefix("-") {
            name = String(name.dropFirst())
        } else {
            return nil
        }
        return DatabaseManager.canonicalProjectFolder("/" + name.replacingOccurrences(of: "-", with: "/"))
    }
}
