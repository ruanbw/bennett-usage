import CryptoKit
import Darwin
import Foundation

/// Adapter for Continue CLI session snapshots.
///
/// Continue writes one JSON document per session to
/// `<globalDir>/sessions/<session UUID>.json`. Per-request usage is stored on
/// each assistant history item at `history[i].message.usage`; the top-level
/// `usage` field is a session aggregate and is deliberately ignored.
public struct ContinueAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "continue"
    public let displayName: String = "Continue CLI"
    public let brandColorHex: String = "#3F8CFF"
    public let sfSymbolIcon: String = "terminal"
    public let defaultPath: String = "~/.continue/sessions"

    public init() {}

    /// Resolve the session directory used by Continue. A configured
    /// `CONTINUE_GLOBAL_DIR` is the parent of `sessions` and must be absolute;
    /// a relative value cannot be resolved reliably because Continue resolves
    /// it from its own working directory, so it is ignored.
    static func sessionsRoot(
        environment: [String: String],
        home: URL
    ) -> URL {
        if let configured = environment["CONTINUE_GLOBAL_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return home
            .appendingPathComponent(".continue", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func resolvedSessionsRoot() -> URL {
        sessionsRoot(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    public func detectDefaultPath() -> URL? {
        let url = Self.resolvedSessionsRoot()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var previous: [String: Int64] = [:]
        if case .fileOffsets(let entries) = cursor {
            previous = entries
        }

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], .fileOffsets([:]))
        }

        var checkpoints: [String: Int64] = [:]
        var records: [UnifiedTokenRecord] = []

        for fileURL in files.sorted(by: { $0.path < $1.path }) {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            guard fileURL.pathExtension.lowercased() == "json",
                  stem.lowercased() != "sessions",
                  let fileUUID = UUID(uuidString: stem) else { continue }

            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true,
                  let byteCount = values?.fileSize,
                  let modifiedAt = values?.contentModificationDate,
                  let identityHash = Self.fileIdentityHash(for: fileURL) else { continue }

            let path = fileURL.path
            let sizeKey = path + "::size"
            let identityKey = path + "::fileIdentity"
            let mtimeMillis = Int64(modifiedAt.timeIntervalSince1970 * 1_000)

            let unchanged = previous[path] == mtimeMillis
                && previous[sizeKey] == Int64(byteCount)
                && previous[identityKey] == identityHash
            if unchanged {
                checkpoints[path] = mtimeMillis
                checkpoints[sizeKey] = Int64(byteCount)
                checkpoints[identityKey] = identityHash
                continue
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = root["sessionId"] as? String,
                  UUID(uuidString: sessionId) == fileUUID,
                  let history = root["history"] as? [[String: Any]] else {
                // A partial or corrupt writer snapshot must be retried. Preserve
                // the prior checkpoint instead of advertising the bad file as scanned.
                if let oldMtime = previous[path] {
                    checkpoints[path] = oldMtime
                    checkpoints[sizeKey] = previous[sizeKey]
                    checkpoints[identityKey] = previous[identityKey]
                }
                continue
            }

            let workspace = (root["workspaceDirectory"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            records.append(contentsOf: Self.records(
                history: history,
                sessionId: sessionId,
                workspaceDirectory: workspace,
                timestamp: modifiedAt
            ))

            checkpoints[path] = mtimeMillis
            checkpoints[sizeKey] = Int64(byteCount)
            checkpoints[identityKey] = identityHash
        }

        return (records, .fileOffsets(checkpoints))
    }

    private static func records(
        history: [[String: Any]],
        sessionId: String,
        workspaceDirectory: String?,
        timestamp: Date
    ) -> [UnifiedTokenRecord] {
        var result: [UnifiedTokenRecord] = []
        var occurrences: [String: Int] = [:]
        let namespacedSessionId = sha256Hex(Data(sessionId.utf8))

        for item in history {
            guard let message = item["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = message["usage"] as? [String: Any],
                  let values = UsageValues(usage),
                  let identity = semanticIdentity(message) else { continue }

            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1

            result.append(UnifiedTokenRecord(
                id: "continue_\(namespacedSessionId)_\(identity)_\(occurrence)",
                sourceId: "continue",
                timestamp: timestamp,
                sessionKey: sessionId,
                projectFolder: workspaceDirectory,
                model: values.model ?? "unknown",
                provider: nil,
                inputTokens: max(0, values.prompt - values.cacheRead - values.cacheWrite),
                outputTokens: values.completion,
                cacheReadTokens: values.cacheRead,
                cacheWriteTokens: values.cacheWrite,
                rawCostUSD: values.costCents.map { Double($0) / 100.0 }
            ))
        }
        return result
    }

    private static func semanticIdentity(_ message: [String: Any]) -> String? {
        let role = message["role"] as? String ?? "assistant"
        let content = message["content"] ?? NSNull()
        let toolCalls = message["toolCalls"] ?? []

        if !(content is String || content is [Any] || content is NSNull) { return nil }
        guard let calls = toolCalls as? [[String: Any]] else { return nil }

        var canonicalCalls: [[String: Any]] = []
        canonicalCalls.reserveCapacity(calls.count)
        for call in calls {
            guard let function = call["function"] as? [String: Any] else { return nil }
            canonicalCalls.append([
                "id": call["id"] ?? NSNull(),
                "function": function,
            ])
        }

        let semantic: [String: Any] = [
            "role": role,
            "content": content,
            "toolCalls": canonicalCalls,
        ]
        return sha256Hex(canonicalJSON(semantic))
    }

    private static func canonicalJSON(_ object: Any) -> Data {
        // All values in the semantic object came from JSONSerialization, so
        // sortedKeys gives recursive deterministic object-key ordering.
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileIdentityHash(for url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let hash = Self.sha256Hex(Data("\(info.st_dev):\(info.st_ino)".utf8))
        return Int64(hash.prefix(15), radix: 16)
    }

    private struct UsageValues {
        let prompt: Int
        let completion: Int
        let cacheRead: Int
        let cacheWrite: Int
        let costCents: Int?
        let model: String?

        init?(_ usage: [String: Any]) {
            guard let prompt = Self.nonNegativeInteger(usage["prompt_tokens"]),
                  let completion = Self.nonNegativeInteger(usage["completion_tokens"]) else { return nil }

            let details: [String: Any]
            if let rawDetails = usage["prompt_tokens_details"], !(rawDetails is NSNull) {
                guard let parsedDetails = rawDetails as? [String: Any] else { return nil }
                details = parsedDetails
            } else {
                details = [:]
            }

            let cacheRead: Int
            if let rawCacheRead = details["cache_read_tokens"], !(rawCacheRead is NSNull) {
                guard let value = Self.nonNegativeInteger(rawCacheRead) else { return nil }
                cacheRead = value
            } else if let rawCached = details["cached_tokens"], !(rawCached is NSNull) {
                guard let value = Self.nonNegativeInteger(rawCached) else { return nil }
                cacheRead = value
            } else {
                cacheRead = 0
            }

            let cacheWrite: Int
            if let rawCacheWrite = details["cache_write_tokens"], !(rawCacheWrite is NSNull) {
                guard let value = Self.nonNegativeInteger(rawCacheWrite) else { return nil }
                cacheWrite = value
            } else {
                cacheWrite = 0
            }

            var costCents: Int?
            if let rawCost = usage["cost_cents"], !(rawCost is NSNull) {
                guard let parsed = Self.nonNegativeInteger(rawCost) else { return nil }
                costCents = parsed
            }

            var model: String?
            if let rawModel = usage["model"], !(rawModel is NSNull) {
                guard let parsed = rawModel as? String else { return nil }
                model = parsed
            }

            // Cache reads and writes are components of prompt_tokens, not usage
            // in addition to it. A larger sum is malformed rather than zero
            // fresh input.
            guard cacheRead <= prompt, cacheWrite <= prompt - cacheRead else { return nil }

            self.prompt = prompt
            self.completion = completion
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.costCents = costCents
            self.model = model
        }

        private static func nonNegativeInteger(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue >= 0,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue <= Double(Int.max) else { return nil }
            return number.intValue
        }
    }
}
