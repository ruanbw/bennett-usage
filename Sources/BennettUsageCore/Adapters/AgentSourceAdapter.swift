import Foundation

public protocol AgentSourceAdapter: Sendable {
    var sourceId: String { get }
    var displayName: String { get }
    var brandColorHex: String { get }
    var sfSymbolIcon: String { get }
    var defaultPath: String { get }

    func detectDefaultPath() -> URL?
    func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor)
}

extension AgentSourceAdapter {
    public var defaultPath: String {
        switch sourceId.lowercased() {
        case "pi": return "~/.pi/agent/sessions"
        case "omp": return "~/.omp/stats.db"
        case "claude": return "~/.claude"
        case "codex": return "~/.codex"
        case "gemini": return "~/.gemini"
        default: return ""
        }
    }
}
