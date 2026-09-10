import XCTest
@testable import BennettUsageCore

private final class MockSyncAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String
    let displayName: String = "Mock Tool"
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"
    let path: URL?
    var recordsToReturn: [UnifiedTokenRecord] = []
    var newCursorToReturn: SyncCursor = .rowId(1)

    init(sourceId: String = "mock", path: URL? = nil) {
        self.sourceId = sourceId
        self.path = path
    }

    func detectDefaultPath() -> URL? {
        return path
    }

    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        return (recordsToReturn, newCursorToReturn)
    }
}

final class SyncCoordinatorTests: XCTestCase {
    func testSyncSingleAdapterNoPathReturnsZero() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let mock = MockSyncAdapter(sourceId: "mock", path: nil)
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 0)
    }

    func testSyncWithRecordsAndPricing() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let mock = MockSyncAdapter(sourceId: "mock_pricing", path: testDir)
        let record = UnifiedTokenRecord(
            id: "rec-1",
            sourceId: "mock_pricing",
            timestamp: Date(),
            dayKey: "2026-09-11",
            sessionKey: "session-1",
            projectFolder: nil,
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: nil
        )
        mock.recordsToReturn = [record]
        mock.newCursorToReturn = .rowId(42)
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 1)

        let cursor = try db.fetchCursor(for: "mock_pricing")
        XCTAssertEqual(cursor, .rowId(42))

        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertGreaterThan(rollups[0].costUSD, 0.0)
    }
}
