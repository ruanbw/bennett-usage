import Foundation

public struct ClaudeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "claude"
    public let displayName: String = "Claude Code"
    public let brandColorHex: String = "#D97706"
    public let sfSymbolIcon: String = "brain.head.profile"
    public let defaultPath: String = "~/.claude"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = (defaultPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Reads Claude session transcripts or JSON files if present
        return ([], cursor ?? .timestamp(Date()))
    }
}
