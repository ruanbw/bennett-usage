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

    func testProjectRankings() async throws {
        let r1 = UnifiedTokenRecord(id: "p1", sourceId: "pi", timestamp: Date(), dayKey: "2026-03-01", sessionKey: "s1", projectFolder: "/Users/dev/projectA", model: "m", provider: nil, inputTokens: 1000, outputTokens: 2000, rawCostUSD: 0.10)
        let r2 = UnifiedTokenRecord(id: "p2", sourceId: "pi", timestamp: Date(), dayKey: "2026-03-02", sessionKey: "s2", projectFolder: "/Users/dev/projectA", model: "m", provider: nil, inputTokens: 500, outputTokens: 500, rawCostUSD: 0.05)
        let r3 = UnifiedTokenRecord(id: "p3", sourceId: "omp", timestamp: Date(), dayKey: "2026-03-03", sessionKey: "s3", projectFolder: "/Users/dev/projectB", model: "m", provider: nil, inputTokens: 100, outputTokens: 100, rawCostUSD: 0.02)
        let r4 = UnifiedTokenRecord(id: "p4", sourceId: "omp", timestamp: Date(), dayKey: "2026-03-04", sessionKey: "s4", projectFolder: nil, model: "m", provider: nil, inputTokens: 10000, outputTokens: 10000, rawCostUSD: 1.00)
        try db.insertRecords([r1, r2, r3, r4])

        let rankings = try await aggregator.fetchProjectRankings(limit: 5)
        XCTAssertEqual(rankings.count, 2)
        XCTAssertEqual(rankings[0].project, "/Users/dev/projectA")
        XCTAssertEqual(rankings[0].totalTokens, 4000)
        XCTAssertEqual(rankings[0].costUSD, 0.15, accuracy: 0.0001)

        XCTAssertEqual(rankings[1].project, "/Users/dev/projectB")
        XCTAssertEqual(rankings[1].totalTokens, 200)
        XCTAssertEqual(rankings[1].costUSD, 0.02, accuracy: 0.0001)
    }

    func testAnnualSummaryAndToolDistribution() async throws {
        let r1 = UnifiedTokenRecord(id: "a1", sourceId: "pi", timestamp: Date(), dayKey: "2026-04-10", sessionKey: "s1", projectFolder: nil, model: "m", provider: nil, inputTokens: 3000, outputTokens: 2000, rawCostUSD: 0.25)
        let r2 = UnifiedTokenRecord(id: "a2", sourceId: "omp", timestamp: Date(), dayKey: "2026-05-15", sessionKey: "s2", projectFolder: nil, model: "m", provider: nil, inputTokens: 1000, outputTokens: 500, rawCostUSD: 0.05)
        let r3 = UnifiedTokenRecord(id: "a3", sourceId: "claude", timestamp: Date(), dayKey: "2026-06-20", sessionKey: "s3", projectFolder: nil, model: "m", provider: nil, inputTokens: 200, outputTokens: 100, rawCostUSD: 0.01)
        try db.insertRecords([r1, r2, r3])

        let summary = try await aggregator.fetchAnnualSummary(year: 2026)
        XCTAssertEqual(summary.annualTokens, 6800)
        XCTAssertEqual(summary.annualCostUSD, 0.31, accuracy: 0.0001)
        XCTAssertEqual(summary.mostActiveTool, "pi")

        let distribution = try await aggregator.fetchToolDistribution(year: 2026)
        XCTAssertEqual(distribution.count, 3)
        XCTAssertEqual(distribution[0].tool, "pi")
        XCTAssertEqual(distribution[0].tokens, 5000)
        XCTAssertEqual(distribution[0].costUSD, 0.25, accuracy: 0.0001)

        XCTAssertEqual(distribution[1].tool, "omp")
        XCTAssertEqual(distribution[1].tokens, 1500)
        XCTAssertEqual(distribution[2].tool, "claude")
        XCTAssertEqual(distribution[2].tokens, 300)
    }

    func testFetchPeriodMetricsLast24Hours() async throws {
        let now = Date()
        let halfHourAgo = now.addingTimeInterval(-1800)
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 3600)

        let r1 = UnifiedTokenRecord(
            id: "24h_1", sourceId: "omp", timestamp: halfHourAgo, dayKey: "2026-09-11",
            sessionKey: "s1", projectFolder: "/tmp/proj1", model: "m", provider: nil,
            inputTokens: 500, outputTokens: 500, rawCostUSD: 0.10
        )
        let r2 = UnifiedTokenRecord(
            id: "24h_2", sourceId: "pi", timestamp: twentyFiveHoursAgo, dayKey: "2026-09-10",
            sessionKey: "s2", projectFolder: "/tmp/proj2", model: "m", provider: nil,
            inputTokens: 1000, outputTokens: 1000, rawCostUSD: 0.20
        )
        try db.insertRecords([r1, r2])

        let metrics = try await aggregator.fetchPeriodMetrics(range: .last24Hours)
        XCTAssertEqual(metrics.totalTokens, 1000)
        XCTAssertEqual(metrics.totalCostUSD, 0.10, accuracy: 0.0001)
        XCTAssertEqual(metrics.mostActiveTool, "omp")
        XCTAssertEqual(metrics.trendPoints.count, 24)
    }

    func testFetchPeriodMetricsToday() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "td_1", sourceId: "omp", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: "/tmp/proj1", model: "m", provider: nil,
            inputTokens: 300, outputTokens: 200, rawCostUSD: 0.05
        )
        try db.insertRecords([r1])

        let metrics = try await aggregator.fetchPeriodMetrics(range: .today)
        XCTAssertEqual(metrics.totalTokens, 500)
        XCTAssertEqual(metrics.totalCostUSD, 0.05, accuracy: 0.0001)
        XCTAssertEqual(metrics.trendPoints.count, 24)
    }

    func testFetchRollingHeatmap() async throws {
        let cells = try await aggregator.fetchHeatmap(range: .pastYear)
        XCTAssertGreaterThanOrEqual(cells.count, 365)
    }

    func testFetchPeriodMetricsWithToolFilter() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "tf_1", sourceId: "claude", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: "/Users/dev/claudeProject", model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.10
        )
        let r2 = UnifiedTokenRecord(
            id: "tf_2", sourceId: "pi", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s2", projectFolder: "/Users/dev/piProject", model: "m", provider: nil,
            inputTokens: 500, outputTokens: 500, rawCostUSD: 0.50
        )
        try db.insertRecords([r1, r2])

        let claudeMetrics = try await aggregator.fetchPeriodMetrics(range: .today, toolFilter: "claude")
        XCTAssertEqual(claudeMetrics.totalTokens, 200)
        XCTAssertEqual(claudeMetrics.totalCostUSD, 0.10, accuracy: 0.0001)
        XCTAssertEqual(claudeMetrics.mostActiveTool, "claude")
        XCTAssertEqual(claudeMetrics.toolDistribution.count, 1)
        XCTAssertEqual(claudeMetrics.toolDistribution.first?.tool, "claude")
        XCTAssertEqual(claudeMetrics.projectRankings.count, 1)
        XCTAssertEqual(claudeMetrics.projectRankings.first?.project, "/Users/dev/claudeProject")

        let piMetrics = try await aggregator.fetchPeriodMetrics(range: .last7Days, toolFilter: "pi")
        XCTAssertEqual(piMetrics.totalTokens, 1000)
        XCTAssertEqual(piMetrics.totalCostUSD, 0.50, accuracy: 0.0001)
        XCTAssertEqual(piMetrics.mostActiveTool, "pi")
        XCTAssertEqual(piMetrics.toolDistribution.count, 1)
        XCTAssertEqual(piMetrics.toolDistribution.first?.tool, "pi")
    }

    func testFetchAgentHealthInfos() async throws {
        let r1 = UnifiedTokenRecord(
            id: "ah_1", sourceId: "claude", timestamp: Date(), dayKey: "2026-09-11",
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.05
        )
        try db.insertRecords([r1])

        let healthInfos = try await aggregator.fetchAgentHealthInfos()
        XCTAssertEqual(healthInfos.count, 4)
        let ids = Set(healthInfos.map { $0.id })
        XCTAssertTrue(ids.contains("pi"))
        XCTAssertTrue(ids.contains("omp"))
        XCTAssertTrue(ids.contains("claude"))
        XCTAssertTrue(ids.contains("codex"))

        let claudeInfo = healthInfos.first(where: { $0.id == "claude" })
        XCTAssertNotNil(claudeInfo)
        XCTAssertEqual(claudeInfo?.recordCount, 1)
        XCTAssertNotNil(claudeInfo?.lastRecordTimestamp)
    }

    func testFetchHeatmapWithToolFilter() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "hm_1", sourceId: "claude", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 200, outputTokens: 300, rawCostUSD: 0.05
        )
        let r2 = UnifiedTokenRecord(
            id: "hm_2", sourceId: "omp", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s2", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 1000, outputTokens: 1000, rawCostUSD: 0.20
        )
        try db.insertRecords([r1, r2])

        let allCells = try await aggregator.fetchHeatmap(range: .pastYear)
        let todayAll = allCells.first(where: { $0.dayKey == todayKey })
        XCTAssertEqual(todayAll?.totalTokens, 2500)

        let filteredCells = try await aggregator.fetchHeatmap(range: .pastYear, toolFilter: "claude")
        let todayFiltered = filteredCells.first(where: { $0.dayKey == todayKey })
        XCTAssertEqual(todayFiltered?.totalTokens, 500)
        XCTAssertEqual(todayFiltered?.costUSD ?? 0.0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(todayFiltered?.toolBreakdown["claude"], 500)
        XCTAssertNil(todayFiltered?.toolBreakdown["omp"])
    }
}
