import Foundation

/// Adapter for Trae (ByteDance AI IDE).
///
/// Since the Feb 2026 pricing change Trae meters token-based Basic/Bonus
/// usage server-side; no documented local per-request token log exists
/// (config lives under `~/.trae` / `~/Library/Application Support/Trae`).
/// This adapter is therefore detection-only (`isSyncStub`): the Agent Health
/// list can show whether Trae is installed, while token ingestion waits for
/// an account-API adapter.
public struct TraeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "trae"
    public let displayName: String = "Trae"
    public let brandColorHex: String = "#FF415C"
    public let sfSymbolIcon: String = "bolt.fill"
    public let defaultPath: String = "~/.trae"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let candidates = [
            "~/.trae",
            "~/Library/Application Support/Trae",
        ]
        for raw in candidates {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public var isSyncStub: Bool { true }
    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Token counts are server-side (Basic/Bonus usage balance).
        return ([], cursor ?? .timestamp(Date()))
    }
}
