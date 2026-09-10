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
    func testDuplicateRecordInsertDoesNotDuplicateRollup() throws {
        let now = Date()
        let record = UnifiedTokenRecord(
            id: "test_dup",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_dup",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheWriteTokens: 100,
            rawCostUSD: 0.05
        )

        try db.insertRecords([record])

        var rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)

        // Inserting duplicate record in separate call should be ignored and not increment rollup
        try db.insertRecords([record])

        rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)

        // Inserting same duplicate in a single batch should also not increment rollup
        try db.insertRecords([record, record])

        rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)
    }

    func testFetchDailyRollupsDateRange() throws {
        let record1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-01",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 100, outputTokens: 50, rawCostUSD: 0.01
        )
        let record2 = UnifiedTokenRecord(
            id: "r2", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-05",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 200, outputTokens: 100, rawCostUSD: 0.02
        )
        let record3 = UnifiedTokenRecord(
            id: "r3", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-10",
            sessionKey: "s3", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 300, outputTokens: 150, rawCostUSD: 0.03
        )
        try db.insertRecords([record1, record2, record3])

        let rangeRollups = try db.fetchDailyRollups(startDate: "2026-09-03", endDate: "2026-09-08")
        XCTAssertEqual(rangeRollups.count, 1)
        XCTAssertEqual(rangeRollups[0].dayKey, "2026-09-05")
        XCTAssertEqual(rangeRollups[0].totalTokens, 300)
    }

    func testFetchRecordsSinceTimestamp() throws {
        let t0 = Date(timeIntervalSince1970: 1700000000)
        let t1 = Date(timeIntervalSince1970: 1700003600) // +1h
        let r1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: t0, dayKey: "2026-09-01",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        let r2 = UnifiedTokenRecord(
            id: "r2", sourceId: "pi", timestamp: t1, dayKey: "2026-09-01",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 20, outputTokens: 20
        )
        try db.insertRecords([r1, r2])

        let recent = try db.fetchRecords(sinceTimestamp: Int64(t1.timeIntervalSince1970 * 1000))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].id, "r2")
        XCTAssertEqual(recent[0].sourceId, "pi")
    }

    func testFetchAvailableYears() throws {
        let r1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: Date(), dayKey: "2025-12-31",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        let r2 = UnifiedTokenRecord(
            id: "r2", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-01",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        try db.insertRecords([r1, r2])

        let years = try db.fetchAvailableYears()
        XCTAssertEqual(years, [2026, 2025])
    }
}
