import Foundation

public struct CodexAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "codex"
    public let displayName: String = "OpenAI Codex"
    public let brandColorHex: String = "#10A37F"
    public let sfSymbolIcon: String = "chevron.left.forwardslash.chevron.right"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.codex" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Reads Codex session logs or CLI cache if present
        return ([], cursor ?? .timestamp(Date()))
    }
}
