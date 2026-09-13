import Foundation

/// Adapter for GitHub Copilot (IDE Chat + CLI).
///
/// Copilot moved to usage-based billing, but per-turn token counts only exist
/// behind the GitHub API / VSCode Chat Debug View — the local logs under
/// `~/.copilot/` and `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/`
/// carry prompts and telemetry without billable token fields. This adapter is
/// therefore detection-only (`isSyncStub`): the Agent Health list can show
/// whether Copilot is installed, while token ingestion waits for an
/// API-backed adapter (user-supplied GitHub token).
public struct CopilotAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "copilot"
    public let displayName: String = "GitHub Copilot"
    public let brandColorHex: String = "#1F2328"
    public let sfSymbolIcon: String = "octagon.fill"
    public let defaultPath: String = "~/.copilot"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let candidates = [
            "~/.copilot",
            "~/Library/Application Support/Code/User/globalStorage/github.copilot-chat",
            "~/.config/github-copilot",
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
        // Token counts require the GitHub API; local logs carry no usage.
        return ([], cursor ?? .timestamp(Date()))
    }
}
