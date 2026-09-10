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
            summary: summary,
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
            summary: nil,
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
            summary: nil,
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
}
