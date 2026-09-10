import XCTest
import SwiftUI
@testable import BennettUsageCore

final class SettingsSheetViewTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!
    private var db: DatabaseManager!
    private var aggregator: MetricsAggregator!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SettingsSheetViewTests_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        db = try DatabaseManager.inMemory()
        aggregator = MetricsAggregator(database: db)
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: suiteName)
        db = nil
        aggregator = nil
        try await super.tearDown()
    }

    @MainActor
    func testSettingsContentViewInitializationWithAggregator() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        var dismissed = false
        let view = SettingsContentView(
            aggregator: aggregator,
            localization: manager,
            onDismiss: { dismissed = true }
        )

        XCTAssertNotNil(view.aggregator)
        XCTAssertEqual(view.localization.selectedLanguage, AppLanguage.system)
        XCTAssertNotNil(view.onDismiss)
        view.onDismiss?()
        XCTAssertTrue(dismissed)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testSettingsContentViewInitializationWithoutAggregator() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let view = SettingsContentView(localization: manager)

        XCTAssertNil(view.aggregator)
        XCTAssertNil(view.onDismiss)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testSettingsSheetViewInitialization() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        var dismissed = false
        let view = SettingsSheetView(aggregator: aggregator, localization: manager) {
            dismissed = true
        }

        XCTAssertNotNil(view.body)
        view.onDismiss()
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testSettingsSheetViewBackwardCompatibleInit() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        var dismissed = false
        let view = SettingsSheetView(localization: manager) {
            dismissed = true
        }

        XCTAssertNil(view.aggregator)
        XCTAssertNotNil(view.body)
        view.onDismiss()
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testLanguageSwitchingInSettingsSheet() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        XCTAssertEqual(manager.selectedLanguage, .system)

        let view = SettingsSheetView(aggregator: aggregator, localization: manager, onDismiss: {})
        XCTAssertNotNil(view)

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.selectedLanguage, .zh)
        XCTAssertEqual(manager.localized(.settings), "设置")
        XCTAssertEqual(manager.localized(.agentHealthSection), "Agent 数据源接入与状态诊断")
        XCTAssertEqual(manager.localized(.pricingSection), "计价与货币")
        XCTAssertEqual(manager.localized(.storageSection), "数据存储与维护")

        manager.setLanguage(.en)
        XCTAssertEqual(manager.selectedLanguage, .en)
        XCTAssertEqual(manager.localized(.settings), "Settings")
        XCTAssertEqual(manager.localized(.agentHealthSection), "Agent Data Sources & Health Diagnostics")
        XCTAssertEqual(manager.localized(.pricingSection), "Pricing & Currency")
        XCTAssertEqual(manager.localized(.storageSection), "Storage & Maintenance")
    }

    @MainActor
    func testPricingEngineCurrencyAndRateSettings() {
        let initialRate = PricingEngine.shared.usdToCnyRate
        let initialCurrency = PricingEngine.shared.preferredCurrency

        PricingEngine.shared.setExchangeRate(7.25)
        XCTAssertEqual(PricingEngine.shared.usdToCnyRate, 7.25)

        PricingEngine.shared.setPreferredCurrency(.cny)
        XCTAssertEqual(PricingEngine.shared.preferredCurrency, .cny)

        PricingEngine.shared.setPreferredCurrency(.usd)
        XCTAssertEqual(PricingEngine.shared.preferredCurrency, .usd)

        // Restore
        PricingEngine.shared.setExchangeRate(initialRate)
        PricingEngine.shared.setPreferredCurrency(initialCurrency)
    }

    func testAggregatorStorageMaintenanceMethods() async throws {
        let record = UnifiedTokenRecord(
            id: "rec_maintenance_1",
            sourceId: "pi",
            timestamp: Date(),
            dayKey: "2026-09-11",
            sessionKey: "s_1",
            projectFolder: "/tmp/project",
            model: "claude-3-opus",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 100,
            cacheWriteTokens: 0,
            rawCostUSD: 0.05
        )
        try db.insertRecords([record])

        let rollupsBefore = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollupsBefore.count, 1)

        try await aggregator.rebuildDailyRollups()
        let rollupsAfter = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollupsAfter.count, 1)
        XCTAssertEqual(rollupsAfter.first?.totalTokens, 1600)

        try await aggregator.clearAllRecords()
        let rollupsCleared = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertTrue(rollupsCleared.isEmpty)
        let stats = try db.fetchRecordStats(forSourceId: "pi")
        XCTAssertEqual(stats.count, 0)
    }
}
