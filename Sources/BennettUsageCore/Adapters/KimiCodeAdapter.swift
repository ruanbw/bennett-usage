import CryptoKit
import Darwin
import Foundation

/// Adapter for the current Kimi Code wire format.
///
/// Kimi Code writes durable `usage.record` events to
/// `sessions/<workDirKey>/<sessionId>/agents/**/wire.jsonl`. Both `turn` and
/// `session` scopes are per-request increments; the latter covers non-turn
/// operations such as compaction rather than a session-total snapshot.
///
/// This adapter intentionally reads only the current wire tree. The legacy
/// `~/.kimi/context.jsonl` format is not a supported source.
public struct KimiCodeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "kimi"
    public let displayName: String = "Kimi Code"
    public let brandColorHex: String = "#6D28D9"
    public let sfSymbolIcon: String = "moon.stars.fill"
    public let defaultPath: String = "~/.kimi-code"

    private enum SnapshotError: Error {
        case unavailable(String)
        case malformedLine(String)
    }

    public init() {}

    public static func resolvedHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".kimi-code", isDirectory: true)
            .standardizedFileURL
    }

    public static func resolvedSessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolvedHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
    }

    public func detectDefaultPath() -> URL? {
        let home = Self.resolvedHome()
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return sessions
        }
        if FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return home
        }
        return nil
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await fetchRecords(from: rootDirectory, since: cursor, requireCompleteSnapshot: false)
    }

    public func fetchCompleteSnapshot(
        from rootDirectory: URL
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await fetchRecords(from: rootDirectory, since: nil, requireCompleteSnapshot: true)
    }

    private func fetchRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?,
        requireCompleteSnapshot: Bool
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        let sessionsRoot = Self.sessionsRoot(under: rootDirectory)
        var previous: [String: FileGeneration] = [:]
        if case .fileGenerations(let generations) = cursor {
            previous = generations
        }

        var checkpoints: [String: FileGeneration] = [:]
        var records: [UnifiedTokenRecord] = []
        var isDirectory: ObjCBool = false
        let rootIsDirectory = FileManager.default.fileExists(
            atPath: sessionsRoot.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        if requireCompleteSnapshot, !rootIsDirectory {
            throw SnapshotError.unavailable(sessionsRoot.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            if requireCompleteSnapshot {
                throw SnapshotError.unavailable(sessionsRoot.path)
            }
            return (records, .fileGenerations(checkpoints))
        }

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.lastPathComponent == "wire.jsonl" else { continue }
            guard let sessionKey = Self.sessionKey(for: fileURL, under: sessionsRoot) else { continue }

            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                if requireCompleteSnapshot { throw error }
                continue
            }
            guard values.isRegularFile == true, let byteCount = values.fileSize else {
                if requireCompleteSnapshot {
                    throw SnapshotError.unavailable(fileURL.path)
                }
                continue
            }

            let path = Self.canonicalPath(for: fileURL)
            let oldCheckpoint = previous[path]
            do {
                let data = try Data(contentsOf: fileURL)
                guard data.count == byteCount else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard let identity = Self.fileIdentity(for: fileURL) else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                let generation = Self.generation(path: path, identity: identity)
                let canContinue = oldCheckpoint.map {
                    guard $0.generation == generation,
                          let oldPrefixHash = $0.prefixHash,
                          $0.offset >= 0,
                          $0.offset <= data.count,
                          $0.size >= 0,
                          $0.size >= $0.offset,
                          $0.size <= data.count,
                          ($0.offset == 0 || data[Int($0.offset) - 1] == 0x0A)
                    else { return false }
                    return oldPrefixHash == Self.consumedPrefixHash(
                        in: data,
                        offset: Int($0.offset)
                    )
                } ?? false
                let startOffset = canContinue ? Int(oldCheckpoint!.offset) : 0
                let parsed = Self.parseCompleteLines(
                    in: data,
                    from: startOffset,
                    path: path,
                    generation: generation,
                    sessionKey: sessionKey,
                    sourceId: sourceId
                )
                guard parsed.didParse else {
                    if requireCompleteSnapshot {
                        throw SnapshotError.malformedLine(path)
                    }
                    if let oldCheckpoint { checkpoints[path] = oldCheckpoint }
                    continue
                }

                records.append(contentsOf: parsed.records)
                checkpoints[path] = FileGeneration(
                    generation: generation,
                    offset: Int64(parsed.consumedOffset),
                    size: Int64(data.count),
                    prefixHash: Self.consumedPrefixHash(in: data, offset: parsed.consumedOffset)
                )
            } catch {
                if requireCompleteSnapshot { throw error }
                if let oldCheckpoint { checkpoints[path] = oldCheckpoint }
            }
        }

        return (records, .fileGenerations(checkpoints))
    }

    // MARK: - Canonical path and generation identity

    static func sessionsRoot(under directory: URL) -> URL {
        if directory.lastPathComponent == "sessions" {
            return directory.standardizedFileURL
        }
        return directory.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
    }

    static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func sessionKey(for fileURL: URL, under sessionsRoot: URL) -> String? {
        let rootComponents = URL(fileURLWithPath: canonicalPath(for: sessionsRoot), isDirectory: true)
            .pathComponents.filter { $0 != "/" }
        let fileComponents = URL(fileURLWithPath: canonicalPath(for: fileURL), isDirectory: true)
            .pathComponents.filter { $0 != "/" }
        guard fileComponents.count >= rootComponents.count + 4,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }

        let relative = Array(fileComponents.dropFirst(rootComponents.count))
        // Official current layout:
        // sessions/<workDirKey>/<sessionId>/agents/<agentPath>/wire.jsonl.
        guard relative[2] == "agents" else { return nil }
        return "\(relative[0])/\(relative[1])"
    }

    private static func fileIdentity(for url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// A generation identifies the canonical wire and its device/inode. The
    /// consumed prefix is checked separately from this stable identity so an
    /// in-place rewrite of any already consumed byte forces a safe rescan.
    static func generation(path: String, identity: String) -> String {
        sha256Hex(Data("kimi-wire-v2\n\(path)\n\(identity)".utf8))
    }

    /// Hash exactly the bytes consumed by the cursor. Because `offset` is
    /// always a complete-line boundary, appending a new line leaves this hash
    /// unchanged while rewriting any consumed line changes it.
    static func consumedPrefixHash(in data: Data, offset: Int) -> String {
        precondition(offset >= 0 && offset <= data.count)
        return sha256Hex(Data(data[..<offset]))
    }

    // MARK: - Current wire payload

    private static func parseCompleteLines(
        in data: Data,
        from startOffset: Int,
        path: String,
        generation: String,
        sessionKey: String,
        sourceId: String
    ) -> (records: [UnifiedTokenRecord], consumedOffset: Int, didParse: Bool) {
        guard startOffset <= data.count else {
            return ([], startOffset, false)
        }
        var records: [UnifiedTokenRecord] = []
        var lineStart = startOffset
        var consumedOffset = startOffset
        let pathHash = sha256Hex(Data(path.utf8))

        while lineStart < data.count,
              let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let line = data[lineStart..<newline]
            let nextOffset = data.index(after: newline)
            if !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: line),
                      let payload = object as? [String: Any] else {
                    return ([], startOffset, false)
                }
                guard let canonical = try? canonicalJSON(payload) else {
                    return ([], startOffset, false)
                }
                if let record = makeRecord(
                    payload,
                    payloadHash: sha256Hex(canonical),
                    pathHash: pathHash,
                    generation: generation,
                    offset: Int64(lineStart),
                    sessionKey: sessionKey,
                    sourceId: sourceId
                ) {
                    records.append(record)
                }
            }
            consumedOffset = nextOffset
            lineStart = nextOffset
        }
        return (records, consumedOffset, true)
    }

    private static func makeRecord(
        _ payload: [String: Any],
        payloadHash: String,
        pathHash: String,
        generation: String,
        offset: Int64,
        sessionKey: String,
        sourceId: String
    ) -> UnifiedTokenRecord? {
        guard payload["type"] as? String == "usage.record",
              let scope = payload["usageScope"] as? String,
              scope == "turn" || scope == "session",
              let milliseconds = nonNegativeInteger(payload["time"]),
              nonEmptyString(payload["agentId"]) != nil,
              let model = nonEmptyString(payload["model"]),
              let usage = payload["usage"] as? [String: Any],
              let inputOther = nonNegativeInteger(usage["inputOther"]),
              let output = nonNegativeInteger(usage["output"]),
              let cacheRead = nonNegativeInteger(usage["inputCacheRead"]),
              let cacheCreation = nonNegativeInteger(usage["inputCacheCreation"]) else { return nil }

        return UnifiedTokenRecord(
            id: "kimi_\(pathHash)_\(generation)_\(offset)_\(payloadHash)",
            sourceId: sourceId,
            timestamp: Date(timeIntervalSince1970: Double(milliseconds) / 1_000.0),
            timestampSource: .event,
            sessionKey: sessionKey,
            // `agentId` identifies the wire's agent, but Kimi does not persist
            // a project/worktree field on usage.record and the path work key
            // is not an official project path. Do not infer either one.
            projectFolder: nil,
            model: model,
            provider: nil,
            inputTokens: Int(inputOther),
            outputTokens: Int(output),
            cacheReadTokens: Int(cacheRead),
            cacheWriteTokens: Int(cacheCreation),
            rawCostUSD: nil
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue >= 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
