import XCTest
@testable import BennettUsageCore

private final class SyncStatusMockAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String
    let displayName = "Sync Status Mock"
    let brandColorHex = "#000000"
    let sfSymbolIcon = "arrow.triangle.2.circlepath"
    let path: URL?
    var shouldFail = false

    init(sourceId: String, path: URL?) {
        self.sourceId = sourceId
        self.path = path
    }

    func detectDefaultPath() -> URL? { path }

    func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        if shouldFail { throw MockError.expected }
        return ([], .rowId(1))
    }

    private enum MockError: Error { case expected }
}

final class SyncStatusTests: XCTestCase {
    func testNoChangeSyncRecordsSuccessfulAttempt() async throws {
        let database = try DatabaseManager.inMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = AdapterRegistry()
        registry.register(SyncStatusMockAdapter(sourceId: "status_success", path: directory))
        let coordinator = SyncCoordinator(database: database, registry: registry)

        let initial = await coordinator.currentSyncStatus()
        XCTAssertEqual(initial, SyncStatus())

        let count = try await coordinator.syncAll()
        let status = await coordinator.currentSyncStatus()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(status.phase, .idle)
        XCTAssertNotNil(status.lastAttemptAt)
        XCTAssertNotNil(status.lastSuccessfulAt)
        XCTAssertTrue(status.failures.isEmpty)
    }

    func testPartialAdapterFailureDoesNotAdvanceSuccessfulTimestamp() async throws {
        let database = try DatabaseManager.inMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = AdapterRegistry()
        let failed = SyncStatusMockAdapter(sourceId: "status_failed", path: directory)
        failed.shouldFail = true
        registry.register(failed)
        registry.register(SyncStatusMockAdapter(sourceId: "status_succeeded", path: directory))
        let coordinator = SyncCoordinator(database: database, registry: registry)

        let count = try await coordinator.syncAll()
        let status = await coordinator.currentSyncStatus()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(status.phase, .idle)
        XCTAssertNotNil(status.lastAttemptAt)
        XCTAssertNil(status.lastSuccessfulAt)
        XCTAssertEqual(status.failures, [SyncFailureSummary(sourceId: "status_failed", stage: .fetch)])
    }

    func testThrottledNoOpDoesNotRecordAttempt() async throws {
        let database = try DatabaseManager.inMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = AdapterRegistry()
        registry.register(SyncStatusMockAdapter(sourceId: "status_throttle", path: directory))
        let coordinator = SyncCoordinator(database: database, registry: registry)

        _ = try await coordinator.syncForUI(minInterval: 60)
        let firstStatus = await coordinator.currentSyncStatus()
        _ = try await coordinator.syncForUI(minInterval: 60)
        let secondStatus = await coordinator.currentSyncStatus()

        XCTAssertEqual(secondStatus, firstStatus)
    }
}
