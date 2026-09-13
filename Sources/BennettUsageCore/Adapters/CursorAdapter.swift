import Foundation

/// Adapter for Cursor (AI IDE).
///
/// Cursor meters usage server-side (dashboard `cursor.com/dashboard` shows
/// per-day spend by model); the local `~/Library/Application Support/Cursor`
/// `state.vscdb` / workspaceStorage databases hold editor state, not
/// per-request token counts. This adapter is therefore detection-only
/// (`isSyncStub`): the Agent Health list can show whether Cursor is
/// installed, while token ingestion waits for a dashboard-API adapter.
public struct CursorAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "cursor"
    public let displayName: String = "Cursor"
    public let brandColorHex: String = "#000000"
    public let sfSymbolIcon: String = "cursorarrow.click.2"
    public let defaultPath: String = "~/Library/Application Support/Cursor"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let candidates = [
            "~/Library/Application Support/Cursor",
            "~/.cursor",
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
        // Token counts live behind the Cursor dashboard API, not on disk.
        return ([], cursor ?? .timestamp(Date()))
    }
}
