import Foundation

public protocol AgentSourceAdapter: Sendable {
    var sourceId: String { get }
    var displayName: String { get }
    var brandColorHex: String { get }
    var sfSymbolIcon: String { get }
    
    func detectDefaultPath() -> URL?
    func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor)
}
