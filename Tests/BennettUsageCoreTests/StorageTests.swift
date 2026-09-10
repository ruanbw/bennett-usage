import XCTest
@testable import BennettUsageCore

final class StorageTests: XCTestCase {
    var db: DatabaseManager!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
    }

    func testInsertRecordsAndQueryDailyRollup() throws {
        let now = Date()
        let record = UnifiedTokenRecord(
            id: "test_1",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheWriteTokens: 100,
            rawCostUSD: 0.05
        )
        
        try db.insertRecords([record], updateCursorFor: "omp", cursor: .rowId(1))
        
        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].dayKey, "2026-09-11")
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)
        
        let savedCursor = try db.fetchCursor(for: "omp")
        XCTAssertEqual(savedCursor, .rowId(1))
    }

    func testRollupUpsertAccumulation() throws {
        let now = Date()
        let record1 = UnifiedTokenRecord(
            id: "test_1",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWriteTokens: 5,
            rawCostUSD: 0.01
        )
        let record2 = UnifiedTokenRecord(
            id: "test_2",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 200,
            outputTokens: 100,
            cacheReadTokens: 20,
            cacheWriteTokens: 10,
            rawCostUSD: 0.02
        )

        try db.insertRecords([record1, record2])

        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 495)
        XCTAssertEqual(rollups[0].inputTokens, 300)
        XCTAssertEqual(rollups[0].outputTokens, 150)
        XCTAssertEqual(rollups[0].cacheTokens, 45)
        XCTAssertEqual(rollups[0].costUSD, 0.03, accuracy: 0.0001)
    }

    func testYearFilterExcludesOtherYears() throws {
        let now = Date()
        let record2025 = UnifiedTokenRecord(
            id: "test_2025",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2025-12-31",
            sessionKey: "sess_old",
            projectFolder: nil,
            model: "claude-3",
            provider: nil,
            inputTokens: 50,
            outputTokens: 50
        )
        let record2026 = UnifiedTokenRecord(
            id: "test_2026",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-01-01",
            sessionKey: "sess_new",
            projectFolder: nil,
            model: "claude-3",
            provider: nil,
            inputTokens: 100,
            outputTokens: 100
        )

        try db.insertRecords([record2025, record2026])

        let rollups2025 = try db.fetchDailyRollups(forYear: 2025)
        XCTAssertEqual(rollups2025.count, 1)
        XCTAssertEqual(rollups2025[0].dayKey, "2025-12-31")

        let rollups2026 = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups2026.count, 1)
        XCTAssertEqual(rollups2026[0].dayKey, "2026-01-01")
    }
}
