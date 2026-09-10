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
}
