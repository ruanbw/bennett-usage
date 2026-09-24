import XCTest
import SwiftUI
@testable import BennettUsageCore

final class MenuBarPopoverViewTests: XCTestCase {
    @MainActor
    func testMenuBarPopoverViewInitialization() {
        var dashboardOpened = false
        var syncTriggered = false
        var quitTriggered = false

        let summary = TodaySummary(
            totalTokens: 142500,
            totalCostUSD: 1.25,
            toolTokens: [
                "omp": 100000,
                "pi": 20000,
                "claude": 15000,
                "codex": 7500
            ],
            toolCosts: [
                "omp": 0.80,
                "pi": 0.15,
                "claude": 0.20,
                "codex": 0.10
            ]
        )

        let view = MenuBarPopoverView(
            model: StatusSummaryModel(summary: summary),
            onOpenDashboard: { dashboardOpened = true },
            onSyncNow: { syncTriggered = true },
            onQuit: { quitTriggered = true }
        )

        XCTAssertNotNil(view.summary)
        XCTAssertEqual(view.summary?.totalTokens, 142500)
        XCTAssertEqual(view.summary?.totalCostUSD, 1.25)
        XCTAssertEqual(view.summary?.toolTokens["omp"], 100000)

        view.onOpenDashboard()
        XCTAssertTrue(dashboardOpened)

        view.onSyncNow()
        XCTAssertTrue(syncTriggered)

        view.onQuit()
        XCTAssertTrue(quitTriggered)
    }

    @MainActor
    func testMenuBarPopoverViewNilSummary() {
        let view = MenuBarPopoverView(
            model: StatusSummaryModel(summary: nil),
            onOpenDashboard: {},
            onSyncNow: {},
            onQuit: {}
        )

        XCTAssertNil(view.summary)
    }

    @MainActor
    func testMenuBarPopoverViewWithSettingsAndLocalization() {
        var settingsOpened = false
        let defaults = UserDefaults(suiteName: "MenuBarPopoverViewTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        localization.setLanguage(.zh)

        let view = MenuBarPopoverView(
            model: StatusSummaryModel(summary: nil),
            localization: localization,
            onOpenDashboard: {},
            onSyncNow: {},
            onQuit: {},
            onOpenSettings: { settingsOpened = true }
        )

        XCTAssertNotNil(view.body)
        view.onOpenSettings?()
        XCTAssertTrue(settingsOpened)
    }

    @MainActor
    func testDashboardAndPopoverObserveTheSamePricingEngine() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        let pricingEngine = PricingEngine()

        let dashboard = DashboardContentView(
            aggregator: aggregator,
            pricingEngine: pricingEngine
        )
        let popover = MenuBarPopoverView(
            model: StatusSummaryModel(summary: nil),
            onOpenDashboard: {},
            onSyncNow: {},
            onQuit: {},
            pricingEngine: pricingEngine
        )

        XCTAssertIdentical(dashboard.pricingEngine, pricingEngine)
        XCTAssertIdentical(popover.pricingEngine, pricingEngine)
        XCTAssertNotNil(dashboard.body)
        XCTAssertNotNil(popover.body)
    }

    @MainActor
    func testPopoverMiniDistributionActiveTools() throws {
        let summary = TodaySummary(
            totalTokens: 100_000,
            totalCostUSD: 0.50,
            toolBreakdown: ["claude": 70_000, "cursor": 30_000]
        )
        let active = MenuBarPopoverView.activeTools(for: summary)
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active[0].id, "claude")
        XCTAssertEqual(active[0].tokens, 70_000)
    }
}
