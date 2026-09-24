import Foundation

public protocol AgentSourceAdapter: Sendable {
    var sourceId: String { get }
    var displayName: String { get }
    var brandColorHex: String { get }
    var sfSymbolIcon: String { get }
    var defaultPath: String { get }
    /// Whether records with the same stable ID can receive a corrected snapshot.
    /// Defaults to `false` so adapters whose records are immutable retain the
    /// efficient insert-and-ignore persistence path.
    var supportsRecordCorrections: Bool { get }

    func detectDefaultPath() -> URL?
    func auxiliaryWatchRoots(for dataRoot: URL) -> [URL]
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
        case "continue": return "~/.continue/sessions"
        case "gemini": return "~/.gemini"
        case "antigravity": return "~/.gemini/antigravity/conversations"
        case "opencode": return "~/.local/share/opencode"
        case "roo": return "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
        case "cline": return "~/.cline/data/sessions"
        case "qwen": return "~/.qwen"
        case "copilot": return "~/.copilot"
        case "cursor": return "~/Library/Application Support/Cursor"
        case "trae": return "~/.trae"
        case "dsh": return "~/.dsh"
        case "goose": return "~/Library/Application Support/Block/goose/sessions/sessions.db"
        case "crush": return "~/Library/Application Support/crush"
        case "kimi": return "~/.kimi-code"
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
        case "continue":
            // Only Continue's per-session JSON snapshots are watched.
            return ContinueAdapter.resolvedSessionsRoot().path
        case "dsh":
            // Transcripts live under sessions/ and projcache lives under
            // storages/session_projcache/sessions/; both are under ~/.dsh.
            // Watching ~/.dsh covers both and prevents projcache events from being ignored.
            if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
                return home
            }
            return "~/.dsh"
        case "cline":
            // Canonical session store only (CLINE_SESSION_DATA_DIR /
            // CLINE_DATA_DIR / CLINE_DIR aware): ~/.cline/data also holds
            // SQLite WAL files and logs that churn during every session.
            return ClineAdapter.sessionsRoot().path
        case "goose":
            // Watch the sessions directory containing sessions.db, including
            // WAL/SHM lifecycle events, while Goose writes the canonical store.
            return GooseAdapter.sessionsRoot().path
        case "crush":
            // projects.json is the registry; each registered data_dir is added
            // as an auxiliary watch root by the adapter.
            return CrushAdapter.resolveGlobalRoot().path
        case "kimi":
            // KIMI_CODE_HOME-aware current wire tree. The legacy
            // ~/.kimi/context.jsonl path is deliberately outside this root.
            return KimiCodeAdapter.resolvedSessionsRoot().path
        default:
            return nil
        }
    }

    /// Additional source trees that should trigger synchronization without
    /// replacing the primary data root passed to `fetchIncrementalRecords`.
    public func auxiliaryWatchRoots(for dataRoot: URL) -> [URL] { [] }

    public var supportsRecordCorrections: Bool { false }

    /// `true` marks adapters whose `fetchIncrementalRecords` is a stub
    /// (returns no records); the coordinator then skips syncing and watching
    /// them entirely. Defaults to `false` for real implementations.
    public var isSyncStub: Bool { false }
}
