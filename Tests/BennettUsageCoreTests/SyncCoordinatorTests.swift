import XCTest
@testable import BennettUsageCore

private final class MockSyncAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String
    let displayName: String = "Mock Tool"
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"
    let path: URL?
    var auxiliaryRoots: [URL] = []
    var recordsToReturn: [UnifiedTokenRecord] = []
    var receivedCursors: [SyncCursor?] = []
    var fetchCallCount = 0
    var newCursorToReturn: SyncCursor = .rowId(1)
    var onFetch: (@Sendable () async -> Void)? = nil
    let supportsRecordCorrections: Bool

    init(
        sourceId: String = "mock",
        path: URL? = nil,
        supportsRecordCorrections: Bool = false,
        onFetch: (@Sendable () async -> Void)? = nil
    ) {
        self.sourceId = sourceId
        self.path = path
        self.supportsRecordCorrections = supportsRecordCorrections
        self.onFetch = onFetch
    }

    func detectDefaultPath() -> URL? {
        return path
    }

    func auxiliaryWatchRoots(for dataRoot: URL) -> [URL] {
        auxiliaryRoots
    }

    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        fetchCallCount += 1
        receivedCursors.append(cursor)
        if let onFetch {
            await onFetch()
        }
        return (recordsToReturn, newCursorToReturn)
    }
}

final class SyncCoordinatorTests: XCTestCase {
    private func makeRecord(id: String, sourceId: String) -> UnifiedTokenRecord {
        UnifiedTokenRecord(
            id: id,
            sourceId: sourceId,
            timestamp: Date(),
            dayKey: "2026-09-11",
            sessionKey: "session",
            projectFolder: nil,
            model: "gpt-4o",
            provider: nil,
            inputTokens: 10,
            outputTokens: 10,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.01
        )
    }

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

    func testSyncPreservesReportedZeroCostAndPricesNilCost() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let mock = MockSyncAdapter(sourceId: "mock_zero_cost", path: testDir)
        mock.recordsToReturn = [
            UnifiedTokenRecord(
                id: "zero-claude",
                sourceId: "mock_zero_cost",
                timestamp: Date(),
                dayKey: "2026-09-11",
                sessionKey: "zero-claude",
                projectFolder: nil,
                model: "claude-3-5-sonnet-20241022",
                provider: "anthropic",
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: 0
            ),
            UnifiedTokenRecord(
                id: "zero-gpt",
                sourceId: "mock_zero_cost",
                timestamp: Date(),
                dayKey: "2026-09-11",
                sessionKey: "zero-gpt",
                projectFolder: nil,
                model: "gpt-4o-2024-08-06",
                provider: "openai",
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: 0
            ),
            UnifiedTokenRecord(
                id: "nil-gpt",
                sourceId: "mock_zero_cost",
                timestamp: Date(),
                dayKey: "2026-09-11",
                sessionKey: "nil-gpt",
                projectFolder: nil,
                model: "gpt-4o-2024-08-06",
                provider: "openai",
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: nil
            )
        ]
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 3)

        let recordsByID = Dictionary(uniqueKeysWithValues: try db.fetchRecords(sinceTimestamp: 0).map { ($0.id, $0) })
        XCTAssertEqual(recordsByID["zero-claude"]?.rawCostUSD, 0)
        XCTAssertEqual(recordsByID["zero-gpt"]?.rawCostUSD, 0)
        guard let pricedNilCost = recordsByID["nil-gpt"]?.rawCostUSD else {
            XCTFail("A nil source cost should be priced during sync")
            return
        }
        XCTAssertGreaterThan(pricedNilCost, 0)
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

    func testCorrectionCapableAdapterUpdatesExistingRecordAndSuppressesEqualRepeatNotification() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        func record(input: Int, output: Int, cost: Double) -> UnifiedTokenRecord {
            UnifiedTokenRecord(
                id: "same-id",
                sourceId: "correctable",
                timestamp: Date(timeIntervalSince1970: 1_000),
                dayKey: "2026-09-11",
                sessionKey: "session",
                projectFolder: nil,
                model: "model",
                provider: nil,
                inputTokens: input,
                outputTokens: output,
                rawCostUSD: cost
            )
        }

        let original = record(input: 10, output: 2, cost: 0.20)
        let corrected = record(input: 25, output: 7, cost: 0.70)
        try db.insertRecords([original])

        let mock = MockSyncAdapter(
            sourceId: "correctable",
            path: testDir,
            supportsRecordCorrections: true
        )
        mock.recordsToReturn = [corrected]
        mock.newCursorToReturn = .rowId(2)
        registry.register(mock)
        let coordinator = SyncCoordinator(database: db, registry: registry)

        let notificationExpectation = expectation(description: "correction notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .bennettUsageDataDidUpdate,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?["ingested"] as? Int, 1)
            notificationExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let changedCount = try await coordinator.syncAll()
        XCTAssertEqual(changedCount, 1)
        await fulfillment(of: [notificationExpectation], timeout: 2.0)

        mock.newCursorToReturn = .rowId(2)
        let repeatedCount = try await coordinator.syncAll()
        XCTAssertEqual(repeatedCount, 0)
        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0), [corrected])
        let rollup = try XCTUnwrap(try db.fetchDailyRollups(forYear: 2026).first)
        XCTAssertEqual(rollup.totalTokens, 32)
        XCTAssertEqual(rollup.costUSD, 0.70, accuracy: 0.000_001)
    }

    func testImmutableAdapterDoesNotCorrectExistingRecord() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let original = makeRecord(id: "same-id", sourceId: "immutable")
        let replacement = UnifiedTokenRecord(
            id: "same-id",
            sourceId: "immutable",
            timestamp: original.timestamp,
            dayKey: original.dayKey,
            sessionKey: original.sessionKey,
            projectFolder: nil,
            model: "replacement",
            provider: nil,
            inputTokens: 25,
            outputTokens: 7,
            rawCostUSD: 0.70
        )
        try db.insertRecords([original])

        let mock = MockSyncAdapter(sourceId: "immutable", path: testDir)
        mock.recordsToReturn = [replacement]
        mock.newCursorToReturn = .rowId(2)
        registry.register(mock)

        let changedCount = try await SyncCoordinator(database: db, registry: registry).syncAll()
        XCTAssertEqual(changedCount, 0)
        let saved = try XCTUnwrap(try db.fetchRecords(sinceTimestamp: 0).first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.model, original.model)
        XCTAssertEqual(saved.inputTokens, original.inputTokens)
        XCTAssertEqual(saved.outputTokens, original.outputTokens)
        XCTAssertEqual(saved.rawCostUSD, original.rawCostUSD)
    }

    func testDatabaseIdentityCursorCodableRoundTrip() throws {
        let cursor = SyncCursor.databaseIdentity("source-db-v2", 42)
        let data = try JSONEncoder().encode(cursor)
        XCTAssertEqual(try JSONDecoder().decode(SyncCursor.self, from: data), cursor)
    }

    func testSyncAllPreservesWatermarkForSameDatabaseIdentity() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        try db.insertRecords([makeRecord(id: "old", sourceId: "identity_source")], updateCursorFor: "identity_source", cursor: .databaseIdentity("db-v1", 7))
        let mock = MockSyncAdapter(sourceId: "identity_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "identity_source")]
        mock.newCursorToReturn = .databaseIdentity("db-v1", 9)
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [.databaseIdentity("db-v1", 7)])
        XCTAssertEqual(try db.fetchTotalRecordCount(), 2)
        XCTAssertEqual(try db.fetchCursor(for: "identity_source"), .databaseIdentity("db-v1", 9))
    }

    func testSyncAllResetsAndRefetchesWhenDatabaseIdentityChanges() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        try db.insertRecords([makeRecord(id: "old", sourceId: "identity_source")], updateCursorFor: "identity_source", cursor: .databaseIdentity("db-v1", 7))
        let mock = MockSyncAdapter(sourceId: "identity_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "identity_source")]
        mock.newCursorToReturn = .databaseIdentity("db-v2", 1)
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [.databaseIdentity("db-v1", 7), nil])
        XCTAssertEqual(try db.fetchTotalRecordCount(), 1)
        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0).map(\.id), ["new"])
        XCTAssertEqual(try db.fetchCursor(for: "identity_source"), .databaseIdentity("db-v2", 1))
    }

    func testSyncAllContinuesWithinSameFileGeneration() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let oldCursor = SyncCursor.fileGenerations([
            "/test/audit-wire.jsonl": FileGeneration(generation: "gen-1", offset: 100, size: 200)
        ])
        try db.insertRecords([makeRecord(id: "old", sourceId: "generation_source")], updateCursorFor: "generation_source", cursor: oldCursor)
        let mock = MockSyncAdapter(sourceId: "generation_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "generation_source")]
        mock.newCursorToReturn = .fileGenerations([
            "/test/audit-wire.jsonl": FileGeneration(generation: "gen-1", offset: 150, size: 250)
        ])
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [oldCursor])
        XCTAssertEqual(try db.fetchTotalRecordCount(), 2)
        XCTAssertEqual(try db.fetchCursor(for: "generation_source"), mock.newCursorToReturn)
    }

    func testSyncAllResetsAndRefetchesWhenFileGenerationChanges() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let oldCursor = SyncCursor.fileGenerations([
            "/test/audit-wire.jsonl": FileGeneration(generation: "gen-1", offset: 100, size: 200)
        ])
        try db.insertRecords([makeRecord(id: "old", sourceId: "generation_source")], updateCursorFor: "generation_source", cursor: oldCursor)
        let mock = MockSyncAdapter(sourceId: "generation_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "generation_source")]
        mock.newCursorToReturn = .fileGenerations([
            "/test/audit-wire.jsonl": FileGeneration(generation: "gen-2", offset: 25, size: 50)
        ])
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [oldCursor, nil])
        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0).map(\.id), ["new"])
        XCTAssertEqual(try db.fetchCursor(for: "generation_source"), mock.newCursorToReturn)
    }

    func testSyncAllCutsOverFromFileOffsetsToFileGenerations() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let oldCursor = SyncCursor.fileOffsets(["/test/audit-wire.jsonl": 100])
        try db.insertRecords([makeRecord(id: "old", sourceId: "generation_source")], updateCursorFor: "generation_source", cursor: oldCursor)
        let mock = MockSyncAdapter(sourceId: "generation_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "generation_source")]
        mock.newCursorToReturn = .fileGenerations([
            "/test/audit-wire.jsonl": FileGeneration(generation: "gen-1", offset: 100, size: 200)
        ])
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [oldCursor, nil])
        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0).map(\.id), ["new"])
        XCTAssertEqual(try db.fetchCursor(for: "generation_source"), mock.newCursorToReturn)
    }

    func testSyncAllCutsOverFromRowIdToDatabaseIdentity() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        try db.insertRecords([makeRecord(id: "old", sourceId: "identity_source")], updateCursorFor: "identity_source", cursor: .rowId(4))
        let mock = MockSyncAdapter(sourceId: "identity_source", path: testDir)
        mock.recordsToReturn = [makeRecord(id: "new", sourceId: "identity_source")]
        mock.newCursorToReturn = .databaseIdentity("db-v1", 1)
        registry.register(mock)

        let count = try await SyncCoordinator(database: db, registry: registry).syncAll()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(mock.receivedCursors, [.rowId(4), nil])
        XCTAssertEqual(try db.fetchTotalRecordCount(), 1)
        XCTAssertEqual(try db.fetchCursor(for: "identity_source"), .databaseIdentity("db-v1", 1))
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

    func testAuxiliaryRootTriggersAdapterAndWatcherUsesNormalizedUniquePaths() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let primary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let auxiliary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: auxiliary)
        }

        let mock = MockSyncAdapter(sourceId: "aux_mock", path: primary)
        mock.auxiliaryRoots = [
            auxiliary,
            URL(fileURLWithPath: auxiliary.path + "/./"),
            primary
        ]
        registry.register(mock)
        let coordinator = SyncCoordinator(database: db, registry: registry)
        await coordinator.startWatching()

        let watched = await coordinator.currentWatchingPaths()
        XCTAssertEqual(watched, [auxiliary.standardizedFileURL.path, primary.standardizedFileURL.path].sorted())

        _ = try await coordinator.syncAll(changedPaths: [auxiliary.appendingPathComponent("event.jsonl").path])
        XCTAssertEqual(mock.fetchCallCount, 1)
    }

    func testUnrelatedChangedPathDoesNotTriggerAuxiliaryWatchAdapter() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let primary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let auxiliary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: auxiliary)
        }

        let mock = MockSyncAdapter(sourceId: "aux_mock", path: primary)
        mock.auxiliaryRoots = [auxiliary]
        registry.register(mock)
        let coordinator = SyncCoordinator(database: db, registry: registry)

        _ = try await coordinator.syncAll(changedPaths: [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path])
        XCTAssertEqual(mock.fetchCallCount, 0)
    }

    func testMissingMainRootWatchesExistingParent() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = parent.appendingPathComponent("not-created/main")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let mock = MockSyncAdapter(sourceId: "missing_root_mock", path: missing)
        registry.register(mock)
        let coordinator = SyncCoordinator(database: db, registry: registry)
        await coordinator.startWatching()

        let watched = await coordinator.currentWatchingPaths()
        XCTAssertEqual(watched, [parent.standardizedFileURL.path])
    }

    func testConcurrentSyncAllAccumulatesDistinctChangedPaths() async throws {
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

        actor Barrier {
            private var isEntered = false
            private var isProceed = false
            private var enterWaiters: [CheckedContinuation<Void, Never>] = []
            private var proceedWaiters: [CheckedContinuation<Void, Never>] = []

            func signalEntered() {
                isEntered = true
                for w in enterWaiters { w.resume() }
                enterWaiters.removeAll()
            }

            func waitUntilEntered() async {
                if isEntered { return }
                await withCheckedContinuation { enterWaiters.append($0) }
            }

            func signalProceed() {
                isProceed = true
                for w in proceedWaiters { w.resume() }
                proceedWaiters.removeAll()
            }

            func waitUntilProceed() async {
                if isProceed { return }
                await withCheckedContinuation { proceedWaiters.append($0) }
            }
        }

        let barrier = Barrier()

        let mockA = MockSyncAdapter(sourceId: "mock_a", path: dirA, onFetch: {
            await barrier.signalEntered()
            await barrier.waitUntilProceed()
        })
        let mockB = MockSyncAdapter(sourceId: "mock_b", path: dirB)
        registry.register(mockA)
        registry.register(mockB)

        let coordinator = SyncCoordinator(database: db, registry: registry)

        // Start sync for adapter A in background task
        let taskA = Task {
            try await coordinator.syncAll(changedPaths: [dirA.appendingPathComponent("session.jsonl").path])
        }

        // Wait until mockA is executing its fetch
        await barrier.waitUntilEntered()

        // While task A is in flight, an event for adapter B arrives
        let taskB = Task {
            try await coordinator.syncAll(changedPaths: [dirB.appendingPathComponent("session.jsonl").path])
        }

        // Wait briefly for taskB to attempt syncAll (and hit isSyncing == true)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Allow task A to finish
        await barrier.signalProceed()
        _ = try await taskA.value
        _ = try await taskB.value

        // Mock A should have been fetched.
        XCTAssertGreaterThanOrEqual(mockA.fetchCallCount, 1)
        // Mock B MUST have been fetched in the coalesced follow-up pass!
        XCTAssertEqual(mockB.fetchCallCount, 1, "Adapter B must be synced in the follow-up pass instead of its paths being dropped")
    }

    func testDshSyncRootAllowsBothSessionsAndProjcache() {
        let adapter = DshAdapter()
        let root = adapter.syncRootPath
        XCTAssertNotNil(root)
        let expanded = URL(fileURLWithPath: (root! as NSString).expandingTildeInPath).standardized.path
        let expected = DshAdapter.resolveHome().standardized.path
        XCTAssertEqual(expanded, expected)
    }

    func testDynamicDirectoryDetectionUpdatesWatcher() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let parentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let dynamicSubdir = parentDir.appendingPathComponent("late_agent")

        final class LateAdapter: AgentSourceAdapter, @unchecked Sendable {
            let sourceId = "late_mock"
            let displayName = "Late Tool"
            let brandColorHex = "#00FF00"
            let sfSymbolIcon = "clock"
            let targetDir: URL
            var fetchCount = 0

            init(targetDir: URL) { self.targetDir = targetDir }
            func detectDefaultPath() -> URL? {
                FileManager.default.fileExists(atPath: targetDir.path) ? targetDir : nil
            }
            func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
                fetchCount += 1
                return ([], .rowId(1))
            }
        }

        let lateAdapter = LateAdapter(targetDir: dynamicSubdir)
        registry.register(lateAdapter)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        await coordinator.startWatching()

        let pathsBefore = await coordinator.currentWatchingPaths()
        XCTAssertFalse(pathsBefore.contains(dynamicSubdir.path))

        // Now directory is created
        try FileManager.default.createDirectory(at: dynamicSubdir, withIntermediateDirectories: true)

        await coordinator.updateWatchingPathsIfNeeded()

        let pathsAfter = await coordinator.currentWatchingPaths()
        XCTAssertTrue(pathsAfter.contains(dynamicSubdir.path), "Newly created directory must be added to watching paths")
    }

    func testAuxiliaryRootsAreDynamicallyAddedAndRemoved() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let primary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let auxiliary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: auxiliary)
        }

        let mock = MockSyncAdapter(sourceId: "dynamic_aux_mock", path: primary)
        registry.register(mock)
        let coordinator = SyncCoordinator(database: db, registry: registry)
        await coordinator.startWatching()
        var watched = await coordinator.currentWatchingPaths()
        XCTAssertFalse(watched.contains(auxiliary.path))

        mock.auxiliaryRoots = [auxiliary]
        await coordinator.updateWatchingPathsIfNeeded()
        watched = await coordinator.currentWatchingPaths()
        XCTAssertTrue(watched.contains(auxiliary.path))

        mock.auxiliaryRoots = []
        await coordinator.updateWatchingPathsIfNeeded()
        watched = await coordinator.currentWatchingPaths()
        XCTAssertFalse(watched.contains(auxiliary.path))
    }
}
