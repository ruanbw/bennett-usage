import XCTest
@testable import BennettUsageCore

private final class MockSyncAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String
    let displayName: String = "Mock Tool"
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"
    let path: URL?
    var recordsToReturn: [UnifiedTokenRecord] = []
    var fetchCallCount = 0
    var newCursorToReturn: SyncCursor = .rowId(1)

    init(sourceId: String = "mock", path: URL? = nil) {
        self.sourceId = sourceId
        self.path = path
    }

    func detectDefaultPath() -> URL? {
        return path
    }

    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        fetchCallCount += 1
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

    func testFSEventsWatcherInitializationAndLifecycle() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectation = XCTestExpectation(description: "FSEvents callback or lifecycle")
        expectation.isInverted = true

        var watcher: FSEventsWatcher? = FSEventsWatcher(paths: [tempDir.path], debounce: 0.1) { paths in
            expectation.fulfill()
        }
        XCTAssertNotNil(watcher)
        watcher = nil
        XCTAssertNil(watcher)
        wait(for: [expectation], timeout: 0.2)
    }

    func testSyncCoordinatorStartWatching() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockSyncAdapter(sourceId: "mock_watch", path: tempDir)
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        await coordinator.startWatching()
    }

    func testSyncAllPostsNotificationOnIngest() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let mock = MockSyncAdapter(sourceId: "mock_notif", path: testDir)
        mock.recordsToReturn = [
            UnifiedTokenRecord(
                id: "notif-rec-1",
                sourceId: "mock_notif",
                timestamp: Date(),
                dayKey: "2026-09-11",
                sessionKey: "s1",
                projectFolder: nil,
                model: "gpt-4o",
                provider: nil,
                inputTokens: 10,
                outputTokens: 10,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: 0.001
            )
        ]
        registry.register(mock)

        let exp = expectation(description: "bennettUsageDataDidUpdate received")
        let observer = NotificationCenter.default.addObserver(
            forName: .bennettUsageDataDidUpdate,
            object: nil,
            queue: .main
        ) { notif in
            let count = notif.userInfo?["ingested"] as? Int
            XCTAssertEqual(count, 1)
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 1)

        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testSyncAllPerformsCursorCutoverWithoutDuplicates() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        // Seed old record with rowId cursor
        let oldRecord = UnifiedTokenRecord(
            id: "old_row_1",
            sourceId: "cutover_source",
            timestamp: Date(),
            dayKey: "2026-09-11",
            sessionKey: "old_sess",
            projectFolder: nil,
            model: "gpt-4o",
            provider: nil,
            inputTokens: 100,
            outputTokens: 100,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.01
        )
        try db.insertRecords([oldRecord], updateCursorFor: "cutover_source", cursor: .rowId(1))
        XCTAssertEqual(try db.fetchTotalRecordCount(), 1)

        // Adapter now uses fileOffsets cursor
        let mock = MockSyncAdapter(sourceId: "cutover_source", path: testDir)
        mock.recordsToReturn = [
            UnifiedTokenRecord(
                id: "new_offset_rec_1",
                sourceId: "cutover_source",
                timestamp: Date(),
                dayKey: "2026-09-11",
                sessionKey: "new_sess",
                projectFolder: nil,
                model: "gpt-4o",
                provider: nil,
                inputTokens: 50,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: 0.005
            )
        ]
        mock.newCursorToReturn = .fileOffsets(["/test/session.jsonl": 128])
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 1)

        // Should contain only the new record, not old + new
        XCTAssertEqual(try db.fetchTotalRecordCount(), 1)
        let records = try db.fetchRecords(sinceTimestamp: 0)
        XCTAssertEqual(records[0].id, "new_offset_rec_1")
        XCTAssertEqual(try db.fetchCursor(for: "cutover_source"), .fileOffsets(["/test/session.jsonl": 128]))
    }

    func testSyncAllWithChangedPathsOnlyReadsMatchingAdapters() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let mockA = MockSyncAdapter(sourceId: "mock_a", path: dirA)
        let mockB = MockSyncAdapter(sourceId: "mock_b", path: dirB)
        registry.register(mockA)
        registry.register(mockB)

        let coordinator = SyncCoordinator(database: db, registry: registry)

        // Event under dirA: only adapter A may be read.
        let count = try await coordinator.syncAll(
            changedPaths: [dirA.appendingPathComponent("session.jsonl").path]
        )
        XCTAssertEqual(count, 0)
        XCTAssertEqual(mockA.fetchCallCount, 1)
        XCTAssertEqual(mockB.fetchCallCount, 0)

        // nil changedPaths = full sync: both adapters read.
        _ = try await coordinator.syncAll()
        XCTAssertEqual(mockA.fetchCallCount, 2)
        XCTAssertEqual(mockB.fetchCallCount, 1)

        // Event outside every adapter root: nothing is read.
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/x.jsonl").path
        _ = try await coordinator.syncAll(changedPaths: [unrelated])
        XCTAssertEqual(mockA.fetchCallCount, 2)
        XCTAssertEqual(mockB.fetchCallCount, 1)
    }
}
