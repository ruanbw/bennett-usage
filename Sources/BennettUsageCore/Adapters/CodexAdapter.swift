import Foundation

public struct CodexAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "codex"
    public let displayName: String = "OpenAI Codex"
    public let brandColorHex: String = "#10A37F"
    public let sfSymbolIcon: String = "chevron.left.forwardslash.chevron.right"
    public let defaultPath: String = "~/.codex"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// No fetch implementation yet: the coordinator skips sync and watch.
    public var isSyncStub: Bool { true }
    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Reads Codex session logs or CLI cache if present
        return ([], cursor ?? .timestamp(Date()))
    }
}
