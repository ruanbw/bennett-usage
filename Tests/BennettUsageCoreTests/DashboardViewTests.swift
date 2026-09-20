import XCTest
import SwiftUI
@testable import BennettUsageCore

final class DashboardViewTests: XCTestCase {
    @MainActor
    func testDashboardViewInitialization() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)

        let view = DashboardView(aggregator: aggregator)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testDashboardViewWithData() async throws {
        let db = try DatabaseManager.inMemory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let record = UnifiedTokenRecord(
            id: "rec-1",
            sourceId: "claude",
            timestamp: Date(),
            dayKey: todayKey,
            sessionKey: "session-1",
            projectFolder: "/test",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 5000,
            outputTokens: 1000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.03
        )
        try db.insertRecords([record])

        let aggregator = MetricsAggregator(database: db)
        let view = DashboardView(aggregator: aggregator)
        XCTAssertNotNil(view.body)
    }

    func testTimeRangeOptionDescriptions() {
        XCTAssertEqual(TimeRangeOption.last24Hours.description, "24 Hours")
        XCTAssertEqual(TimeRangeOption.today.description, "Today")
        XCTAssertEqual(TimeRangeOption.last7Days.description, "Last 7 Days")
        XCTAssertEqual(TimeRangeOption.last30Days.description, "Last 30 Days")
        XCTAssertEqual(TimeRangeOption.pastYear.description, "Past Year")
        XCTAssertEqual(TimeRangeOption.year(2026).description, "2026")
    }

    @MainActor
    func testDashboardViewWithLocalization() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let defaults = UserDefaults(suiteName: "DashboardViewTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)

        localization.setLanguage(.zh)
        let zhView = DashboardView(aggregator: aggregator, localization: localization, showSettingsInitially: true)
        XCTAssertNotNil(zhView.body)

        localization.setLanguage(.en)
        let enView = DashboardView(aggregator: aggregator, localization: localization, showSettingsInitially: false)
        XCTAssertNotNil(enView.body)
    }

    @MainActor
    func testDashboardContentViewInitialization() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let contentView = DashboardContentView(aggregator: aggregator)
        XCTAssertNotNil(contentView.body)
    }

    @MainActor
    func testDashboardContentViewWithLocalization() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let defaults = UserDefaults(suiteName: "DashboardContentTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        localization.setLanguage(.zh)

        let view = DashboardContentView(aggregator: aggregator, localization: localization)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testAgentFilterOptionsFollowTheSelectedRange() {
        // Options are exactly the agents with usage in the range, so an agent
        // that was idle in it (e.g. Cline on a day it never ran) is not offered.
        XCTAssertEqual(
            DashboardContentView.agentFilterOptions(activeAgents: ["claude", "codex"], selectedAgent: nil),
            ["claude", "codex"]
        )
        // A range with no recorded usage offers nothing but "All Agents".
        XCTAssertEqual(DashboardContentView.agentFilterOptions(activeAgents: [], selectedAgent: nil), [])

        // An active filter stays listed even when the newly selected range has no
        // usage for it: hiding it would leave an invisible filter in force.
        XCTAssertEqual(
            DashboardContentView.agentFilterOptions(activeAgents: ["claude"], selectedAgent: "cline"),
            ["claude", "cline"]
        )
        XCTAssertEqual(
            DashboardContentView.agentFilterOptions(activeAgents: [], selectedAgent: "cline"),
            ["cline"]
        )
        // Matching is case-insensitive, so the selected agent never duplicates.
        XCTAssertEqual(
            DashboardContentView.agentFilterOptions(activeAgents: ["cline"], selectedAgent: "Cline"),
            ["cline"]
        )
        XCTAssertEqual(
            DashboardContentView.agentFilterOptions(activeAgents: ["claude"], selectedAgent: ""),
            ["claude"]
        )
    }

    func testNavigationItemCases() {
        let items = NavigationItem.allCases
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains(.dashboard))
        XCTAssertTrue(items.contains(.settings))
        XCTAssertEqual(NavigationItem.dashboard.id, "dashboard")
        XCTAssertEqual(NavigationItem.settings.id, "settings")
    }

    @MainActor
    func testSidebarViewInitialization() throws {
        let defaults = UserDefaults(suiteName: "SidebarTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        var syncCalled = false

        let view = SidebarView(
            selectedItem: .constant(.dashboard),
            agentCount: 4,
            isSyncing: false,
            lastSyncDate: Date(),
            onSyncNow: { syncCalled = true },
            localization: localization
        )
        XCTAssertNotNil(view.body)
        XCTAssertFalse(syncCalled)
    }

    @MainActor
    func testDashboardViewNavigationItems() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)

        let defaultView = DashboardView(aggregator: aggregator, localization: .shared, showSettingsInitially: false)
        XCTAssertNotNil(defaultView.body)

        let settingsView = DashboardView(aggregator: aggregator, localization: .shared, showSettingsInitially: true)
        XCTAssertNotNil(settingsView.body)
    }

    @MainActor
    func testDashboardContentViewWithDifferentRanges() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)

        for range in [TimeRangeOption.last24Hours, .today, .last7Days, .last30Days, .pastYear, .year(2026)] {
            let contentView = DashboardContentView(aggregator: aggregator, localization: .shared, initialRange: range)
            XCTAssertNotNil(contentView.body)
        }
    }
    func testHeatmapDisplayModeCases() {
        let modes = HeatmapDisplayMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertTrue(modes.contains(.calendar))
        XCTAssertTrue(modes.contains(.monthlyTrend))
        XCTAssertEqual(HeatmapDisplayMode.calendar.id, "calendar")
        XCTAssertEqual(HeatmapDisplayMode.monthlyTrend.id, "monthlyTrend")
    }

    @MainActor
    func testDashboardContentViewAnnualPanoramaStateAndDisplay() async throws {
        let db = try DatabaseManager.inMemory()
        let r1 = UnifiedTokenRecord(
            id: "rec-yr1",
            sourceId: "pi",
            timestamp: Date(),
            dayKey: "2026-02-14",
            sessionKey: "s1",
            projectFolder: "/test",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 10000,
            outputTokens: 2000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.05
        )
        try db.insertRecords([r1])
        let aggregator = MetricsAggregator(database: db)

        let contentView = DashboardContentView(
            aggregator: aggregator,
            localization: .shared,
            initialRange: .year(2026)
        )
        XCTAssertNotNil(contentView.body)

        let summary = try await aggregator.fetchAnnualSummary(year: 2026)
        XCTAssertEqual(summary.annualTokens, 12000)
        XCTAssertEqual(summary.annualCostUSD, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.mostActiveTool, "pi")
        XCTAssertEqual(summary.activeDays, 1)
        XCTAssertEqual(summary.totalDays, 365)

        let annualHeatmap = try await aggregator.fetchAnnualHeatmap(year: 2026)
        let calendar = Calendar(identifier: .gregorian)
        if calendar.component(.year, from: Date()) == 2026 {
            XCTAssertEqual(annualHeatmap.count, calendar.ordinality(of: .day, in: .year, for: Date())!)
        } else {
            XCTAssertEqual(annualHeatmap.count, 365)
        }
        let dayCell = annualHeatmap.first(where: { $0.dayKey == "2026-02-14" })
        XCTAssertEqual(dayCell?.totalTokens, 12000)
        XCTAssertEqual(dayCell?.intensityLevel, 4)
    }

    func testHeroMetricsRibbonCalculations() throws {
        let metrics = PeriodMetrics(
            totalTokens: 1_250_000,
            inputTokens: 800_000,
            outputTokens: 200_000,
            cacheWriteTokens: 150_000,
            cacheReadTokens: 100_000,
            totalCostUSD: 4.50,
            toolDistribution: [("claude", 1_250_000, 4.50)],
            modelDistribution: [("claude-3-5-sonnet", 1_250_000, 4.50)],
            projectRankings: [("/test/proj", 1_250_000, 4.50)],
            trendPoints: []
        )
        // Cacheable tokens = 800_000 (input) + 150_000 (write) + 100_000 (read) = 1_050_000.
        // Prompt cache hit rate = cacheReadTokens / cacheable = 100_000 / 1_050_000 ≈ 0.0952.
        XCTAssertEqual(metrics.cacheHitRate, 100_000.0 / 1_050_000.0, accuracy: 0.01)

        // When fresh input tokens are 0, cacheRead / (cacheWrite + cacheRead) = 100_000 / 250_000 = 0.4.
        let zeroInputMetrics = PeriodMetrics(
            totalTokens: 250_000,
            inputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 150_000,
            cacheReadTokens: 100_000,
            totalCostUSD: 4.50,
            toolDistribution: [("claude", 250_000, 4.50)],
            modelDistribution: [("claude-3-5-sonnet", 250_000, 4.50)],
            projectRankings: [("/test/proj", 250_000, 4.50)],
            trendPoints: []
        )
        XCTAssertEqual(zeroInputMetrics.cacheHitRate, 0.4, accuracy: 0.01)

        // Verify token formatting and spend calculations used in hero section & ribbon
        XCTAssertEqual(TokenFormatter.formatFull(metrics.totalTokens), "1,250,000")
        XCTAssertEqual(TokenFormatter.formatCompact(metrics.totalTokens), "1.25M")
        XCTAssertEqual(TokenFormatter.formatCompact(metrics.inputTokens), "800k")
        XCTAssertEqual(TokenFormatter.formatCompact(metrics.outputTokens), "200k")
        XCTAssertEqual(TokenFormatter.formatCompact(metrics.cacheWriteTokens), "150k")
        XCTAssertEqual(TokenFormatter.formatCompact(metrics.cacheReadTokens), "100k")
        XCTAssertEqual(String(format: "%.1f%%", zeroInputMetrics.cacheHitRate * 100), "40.0%")
    }
}

extension PeriodMetrics {
    public init(
        totalTokens: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalCostUSD: Double = 0.0,
        toolDistribution: [(tool: String, tokens: Int, costUSD: Double)] = [],
        modelDistribution: [(model: String, tokens: Int, costUSD: Double)] = [],
        projectRankings: [(project: String, totalTokens: Int, costUSD: Double)] = [],
        trendPoints: [TrendPoint] = [],
        mostActiveTool: String = ""
    ) {
        self.init(
            totalTokens: totalTokens,
            totalCostUSD: totalCostUSD,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            mostActiveTool: mostActiveTool,
            trendPoints: trendPoints,
            toolDistribution: toolDistribution,
            projectRankings: projectRankings,
            modelDistribution: modelDistribution
        )
    }
}
