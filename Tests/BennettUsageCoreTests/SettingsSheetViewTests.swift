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
    func testSettingsCategoryPropertiesAndLocalization() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        manager.setLanguage(.en)

        XCTAssertEqual(SettingsCategory.allCases.count, 5)
        for category in SettingsCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
            XCTAssertFalse(category.systemImage.isEmpty)
            XCTAssertFalse(category.title(localization: manager).isEmpty)
            XCTAssertFalse(category.fullTitle(localization: manager).isEmpty)
            XCTAssertFalse(category.subtitle(localization: manager).isEmpty)
        }

        manager.setLanguage(.zh)
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.title(localization: manager).isEmpty)
            XCTAssertFalse(category.fullTitle(localization: manager).isEmpty)
            XCTAssertFalse(category.subtitle(localization: manager).isEmpty)
        }
    }

    @MainActor
    func testSettingsViewsWithSpecificInitialCategory() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let contentView = SettingsContentView(
            aggregator: aggregator,
            localization: manager,
            initialCategory: .agents,
            onDismiss: {}
        )
        XCTAssertNotNil(contentView.body)

        var dismissed = false
        let sheetView = SettingsSheetView(
            aggregator: aggregator,
            localization: manager,
            initialCategory: .storage,
            onDismiss: { dismissed = true }
        )
        XCTAssertEqual(sheetView.initialCategory, .storage)
        XCTAssertNotNil(sheetView.body)
        sheetView.onDismiss()
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
    func testStorageClearCopyPreservesSourceLogsSemantics() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        manager.setLanguage(.en)
        XCTAssertEqual(manager.localized(.clearAllRecords), "Clear Local Usage Cache...")
        XCTAssertTrue(manager.localized(.clearRecordsDescription).contains("source agent logs are preserved"))
        XCTAssertTrue(manager.localized(.clearRecordsConfirmMessage).contains("can be imported again on the next sync"))

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.localized(.clearAllRecords), "清空本地统计缓存...")
        XCTAssertTrue(manager.localized(.clearRecordsDescription).contains("原始日志会保留"))
        XCTAssertTrue(manager.localized(.clearRecordsConfirmMessage).contains("下次同步时重新导入"))
    }

    @MainActor
    func testSettingsRemainingCopyRespondsToLanguage() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let englishView = SettingsContentView(
            aggregator: aggregator,
            localization: manager,
            initialCategory: .agents
        )
        XCTAssertNotNil(englishView.body)

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.localized(.agentActive), "正常")
        XCTAssertEqual(manager.localized(.agentRecords, arguments: 12), "12 条记录")
        XCTAssertEqual(manager.localized(.currencySummary), "美元 USD ($) / 人民币 CNY (¥)")
        XCTAssertEqual(manager.localized(.privacyDescription).contains("Token"), true)
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

    @MainActor
    private func hostedGeneralPane(localization: LocalizationManager) -> NSHostingView<AnyView> {
        let sheetWidth: CGFloat = 750
        let sheetHeight: CGFloat = 510
        let root = AnyView(SettingsContentView(
            aggregator: aggregator,
            localization: localization,
            onDismiss: {}
        ).frame(width: sheetWidth, height: sheetHeight))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    @MainActor
    func testAgentHealthRowDisplaysRecordCountInEnglishAndChinese() async throws {
        let record = UnifiedTokenRecord(
            id: "settings_agent_row",
            sourceId: "pi",
            timestamp: Date(),
            dayKey: UnifiedTokenRecord.dayKey(for: Date()),
            sessionKey: "settings-test",
            projectFolder: "/tmp/settings-test",
            model: "test-model",
            provider: "test-provider",
            inputTokens: 1,
            outputTokens: 1
        )
        try db.insertRecords([record])
        let agentInfos = try await aggregator.fetchAgentHealthInfos()
        let piInfo = try XCTUnwrap(agentInfos.first(where: { $0.id == "pi" }))

        for (language, expectedText) in [(AppLanguage.en, "1 records"), (.zh, "1 条记录")] {
            let manager = LocalizationManager(userDefaults: testDefaults)
            manager.setLanguage(language)
            XCTAssertEqual(
                SettingsContentView.agentRecordsText(for: piInfo, localization: manager),
                expectedText
            )
        }
    }

    @MainActor
    private func menuControls(in view: NSView) -> [SettingsMenuControl] {
        var found: [SettingsMenuControl] = []
        if let control = view as? SettingsMenuControl { found.append(control) }
        for sub in view.subviews { found.append(contentsOf: menuControls(in: sub)) }
        return found
    }

    @MainActor
    private func valueLabel(in control: SettingsMenuControl) -> NSView? {
        for sub in control.subviews where sub.identifier?.rawValue == "settings.menu.value" {
            return sub
        }
        return nil
    }

    @MainActor
    func testSettingsDropdownsAreRightAlignedWithCardEdge() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let hosting = hostedGeneralPane(localization: manager)

        let controls = menuControls(in: hosting)
        XCTAssertEqual(controls.count, 2, "general pane should expose two dropdowns")

        // The card's trailing content edge: sheet width minus the detail pane's
        // 24pt padding and the card's 16pt padding.
        let expectedTrailingEdge: CGFloat = 750 - 40
        for control in controls {
            let frame = control.convert(control.bounds, to: nil)
            XCTAssertEqual(frame.maxX, expectedTrailingEdge, accuracy: 1.0,
                           "dropdown must sit flush with the card's trailing edge")
            XCTAssertGreaterThan(frame.width, 0)
            if let label = valueLabel(in: control) {
                let labelFrame = label.convert(label.bounds, to: control)
                XCTAssertLessThan(labelFrame.maxX, frame.width,
                                  "value text must not run past the control")
                XCTAssertGreaterThan(labelFrame.minX, 0)
            }
        }
    }

    @MainActor
    func testSettingsMenuControlExposesDynamicAccessibilityState() {
        let control = SettingsMenuControl(
            title: "System Default",
            accessibilityLabel: "Language",
            options: ["System Default", "English"],
            onSelect: { _ in }
        )

        XCTAssertTrue(control.isAccessibilityElement())
        XCTAssertEqual(control.accessibilityRole(), .popUpButton)
        XCTAssertEqual(control.accessibilityLabel(), "Language")
        XCTAssertEqual(control.accessibilityValue() as? String, "System Default")
        XCTAssertFalse(control.isAccessibilityExpanded())

        control.setMenuExpandedForTesting(true)
        XCTAssertTrue(control.isAccessibilityExpanded())
        control.update(
            title: "English",
            accessibilityLabel: "语言",
            options: ["System Default", "English"],
            onSelect: { _ in }
        )
        XCTAssertEqual(control.accessibilityLabel(), "语言")
        XCTAssertEqual(control.accessibilityValue() as? String, "English")
        XCTAssertTrue(control.isAccessibilityExpanded())

        control.performSelectionForTesting(at: 0)
        XCTAssertEqual(control.accessibilityValue() as? String, "System Default")
        XCTAssertTrue(control.isAccessibilityExpanded())
    }

    @MainActor
    func testLanguageDropdownSelectionUpdatesLocalization() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        manager.setLanguage(.system)
        let hosting = hostedGeneralPane(localization: manager)

        let controls = menuControls(in: hosting)
        XCTAssertEqual(controls.count, 2)
        guard let languageControl = controls.first else {
            return XCTFail("language dropdown not found")
        }

        XCTAssertEqual(manager.selectedLanguage, .system)
        // Selecting English (last option) must drive the localization manager.
        let englishIndex = manager.availableLanguages.firstIndex(of: .en)!
        languageControl.performSelectionForTesting(at: englishIndex)
        XCTAssertEqual(manager.selectedLanguage, .en)
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
