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
        case "antigravity": return "~/.gemini/antigravity/conversations"
        default: return ""
        }
    }
}

extension AgentSourceAdapter {
    /// Statically known data root for the sync infrastructure, when it is
    /// narrower than `defaultPath` (keeps FSEvents quiet on unrelated writes
    /// and avoids overlapping trees between adapters). `nil` (the default)
    /// means "no static narrowing knowledge" — the coordinator falls back to
    /// `detectDefaultPath()`. Custom/third-party adapters need no override.
    public var syncRootPath: String? {
        switch sourceId.lowercased() {
        case "gemini":
            // GeminiAdapter only reads tmp/<projectHash>/chats/session-*.jsonl;
            // ~/.gemini itself also contains antigravity/conversations, which
            // has its own adapter and watch root.
            return "~/.gemini/tmp"
        default:
            return nil
        }
    }

    /// `true` marks adapters whose `fetchIncrementalRecords` is a stub
    /// (returns no records); the coordinator then skips syncing and watching
    /// them entirely. Defaults to `false` for real implementations.
    public var isSyncStub: Bool { false }
}
