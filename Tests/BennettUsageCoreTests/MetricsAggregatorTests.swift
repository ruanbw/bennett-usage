import XCTest
@testable import BennettUsageCore

final class MetricsAggregatorTests: XCTestCase {
    var db: DatabaseManager!
    var aggregator: MetricsAggregator!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
        aggregator = MetricsAggregator(database: db)
    }

    func testHeatmapIntensityScaling() async throws {
        let r1 = UnifiedTokenRecord(id: "1", sourceId: "omp", timestamp: Date(), dayKey: "2026-01-15", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 5000, outputTokens: 5000)
        let r2 = UnifiedTokenRecord(id: "2", sourceId: "omp", timestamp: Date(), dayKey: "2026-02-20", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 500_000, outputTokens: 500_000)
        try db.insertRecords([r1, r2])

        let cells = try await aggregator.fetchAnnualHeatmap(year: 2026)
        XCTAssertTrue(cells.count >= 365)
        
        let jan15 = cells.first(where: { $0.dayKey == "2026-01-15" })
        let feb20 = cells.first(where: { $0.dayKey == "2026-02-20" })
        let emptyDay = cells.first(where: { $0.dayKey == "2026-03-01" })

        XCTAssertEqual(emptyDay?.intensityLevel, 0)
        XCTAssertTrue(jan15!.intensityLevel > 0)
        XCTAssertTrue(feb20!.intensityLevel >= jan15!.intensityLevel)
    }

    func testTodaySummary() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(id: "today1", sourceId: "pi", timestamp: Date(), dayKey: todayKey, sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 100, outputTokens: 200, rawCostUSD: 0.05)
        let r2 = UnifiedTokenRecord(id: "today2", sourceId: "omp", timestamp: Date(), dayKey: todayKey, sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 300, outputTokens: 400, rawCostUSD: 0.10)
        try db.insertRecords([r1, r2])

        let summary = try await aggregator.fetchTodaySummary()
        XCTAssertEqual(summary.totalTokens, 1000)
        XCTAssertEqual(summary.totalCostUSD, 0.15, accuracy: 0.0001)
        XCTAssertEqual(summary.toolTokens["pi"], 300)
        XCTAssertEqual(summary.toolTokens["omp"], 700)
        XCTAssertEqual(summary.toolCosts["pi"] ?? 0.0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.toolCosts["omp"] ?? 0.0, 0.10, accuracy: 0.0001)
    }
}
