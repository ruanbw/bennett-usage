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
        case "opencode": return "~/.local/share/opencode"
        case "roo": return "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
        case "qwen": return "~/.qwen"
        case "copilot": return "~/.copilot"
        case "cursor": return "~/Library/Application Support/Cursor"
        case "trae": return "~/.trae"
        case "dsh": return "~/.dsh"
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
        case "qwen":
            // Same forked layout as Gemini: only tmp/ carries chats.
            if let home = ProcessInfo.processInfo.environment["QWEN_HOME"], !home.isEmpty {
                return (home as NSString).appendingPathComponent("tmp")
            }
            return "~/.qwen/tmp"
        case "claude":
            // Transcripts live under projects/; the ~/.claude root also holds
            // todos/history noise that needs no watching.
            return "~/.claude/projects"
        case "codex":
            // Date-sharded rollout logs; the ~/.codex root holds auth/config.
            return "~/.codex/sessions"
        case "dsh":
            // Transcripts + projcache live under sessions/; the home root
            // also holds credentials/settings that need no watching.
            if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
                return (home as NSString).appendingPathComponent("sessions")
            }
            return "~/.dsh/sessions"
        default:
            return nil
        }
    }

    /// `true` marks adapters whose `fetchIncrementalRecords` is a stub
    /// (returns no records); the coordinator then skips syncing and watching
    /// them entirely. Defaults to `false` for real implementations.
    public var isSyncStub: Bool { false }
}
