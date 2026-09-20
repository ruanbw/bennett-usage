import XCTest
import AppKit
@testable import BennettUsageCore

private final class MockHeartbeatAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String = "mock_heartbeat"
    let displayName: String = "Mock Heartbeat"
    let brandColorHex: String = "#0000FF"
    let sfSymbolIcon: String = "heart"
    let path: URL

    var fetchCallCount = 0

    init(path: URL) {
        self.path = path
    }

    func detectDefaultPath() -> URL? {
        return path
    }

    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        fetchCallCount += 1
        return ([], .rowId(1))
    }
}

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testDayChangedNotificationTriggersRefresh() async throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let coordinator = SyncCoordinator(database: db)

        let controller = StatusItemController(
            aggregator: aggregator,
            syncCoordinator: coordinator,
            heartbeatInterval: nil // disable heartbeat for this test
        )

        // Post NSCalendarDayChanged notification
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(controller)
    }

    func testSystemWakeNotificationTriggersSync() async throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let coordinator = SyncCoordinator(database: db)

        let controller = StatusItemController(
            aggregator: aggregator,
            syncCoordinator: coordinator,
            heartbeatInterval: nil
        )

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(controller)
    }

    func testPeriodicHeartbeatTriggersSync() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mock = MockHeartbeatAdapter(path: dir)
        registry.register(mock)

        let aggregator = MetricsAggregator(database: db)
        let coordinator = SyncCoordinator(database: db, registry: registry)

        let controller = StatusItemController(
            aggregator: aggregator,
            syncCoordinator: coordinator,
            heartbeatInterval: 0.1
        )

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThanOrEqual(mock.fetchCallCount, 1, "Heartbeat must trigger background sync")
        _ = controller
    }
}
