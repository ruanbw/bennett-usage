import XCTest
@testable import BennettUsageCore

final class LocalizationTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BennettUsageLocalizationTests_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultSelectedLanguageIsSystem() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        XCTAssertEqual(manager.selectedLanguage, .system)
    }

    func testLanguagePersistence() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        manager.setLanguage(.zh)
        XCTAssertEqual(manager.selectedLanguage, .zh)

        let reloaded = LocalizationManager(userDefaults: testDefaults)
        XCTAssertEqual(reloaded.selectedLanguage, .zh)
    }

    func testEffectiveLanguageResolution() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        manager.setLanguage(.en)
        XCTAssertEqual(manager.effectiveLanguage, .en)

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.effectiveLanguage, .zh)

        manager.setLanguage(.system)
        // With system, should resolve to either .zh or .en depending on preferredLanguages
        let systemEffective = manager.effectiveLanguage
        XCTAssertTrue(systemEffective == .en || systemEffective == .zh)
    }

    func testTranslationLookupEnglishAndChinese() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        manager.setLanguage(.en)
        XCTAssertEqual(manager.localized(.appName), "Bennett Usage")
        XCTAssertEqual(manager.localized(.syncNow), "Sync Now")
        XCTAssertEqual(manager.localized(.todaysTokens), "Today's Tokens")
        XCTAssertEqual(manager.localized(.tokenUnit), "tokens")

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.localized(.appName), "Bennett Usage")
        XCTAssertEqual(manager.localized(.syncNow), "立即同步")
        XCTAssertEqual(manager.localized(.todaysTokens), "今日 Token")
        XCTAssertEqual(manager.localized(.tokenUnit), "Token")
    }

    func testQueryFreshnessAndOverflowCopyIsBilingual() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        XCTAssertEqual(manager.localized(.dataUpdatedJustNow, language: .en), "Data updated just now")
        XCTAssertEqual(manager.localized(.dataUpdatedMinutesAgo, language: .en, arguments: 5), "Data updated 5 mins ago")
        XCTAssertEqual(manager.localized(.moreToolsCount, language: .en, arguments: 2), "+2 More")

        XCTAssertEqual(manager.localized(.dataUpdatedJustNow, language: .zh), "数据刚刚更新")
        XCTAssertEqual(manager.localized(.dataUpdatedMinutesAgo, language: .zh, arguments: 5), "数据更新于 5 分钟前")
        XCTAssertEqual(manager.localized(.moreToolsCount, language: .zh, arguments: 2), "+2 更多")
    }

    func testTranslationWithArguments() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        manager.setLanguage(.en)
        let enText = manager.localized(.activeDaysCount, arguments: 42)
        XCTAssertEqual(enText, "42 active days")

        manager.setLanguage(.zh)
        let zhText = manager.localized(.activeDaysCount, arguments: 42)
        XCTAssertEqual(zhText, "42 个活跃天数")
    }

    func testFallbackToEnglishWhenTranslationMissing() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let customLang = AppLanguage(code: "fr", displayName: "Français")
        manager.registerLanguage(customLang, translations: [
            .appName: "Bennett Usage FR"
            // .syncNow missing
        ])

        manager.setLanguage(customLang)
        XCTAssertEqual(manager.localized(.appName), "Bennett Usage FR")
        // Falls back to English for missing key
        XCTAssertEqual(manager.localized(.syncNow), "Sync Now")
    }

    func testExtensibilityRegisteringNewLanguage() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let jaLang = AppLanguage(code: "ja", displayName: "日本語")

        XCTAssertFalse(manager.availableLanguages.contains(where: { $0.code == "ja" }))

        manager.registerLanguage(jaLang, translations: [
            .appName: "Bennett Usage",
            .syncNow: "今すぐ同期",
            .todaysTokens: "今日のトークン"
        ])

        XCTAssertTrue(manager.availableLanguages.contains(where: { $0.code == "ja" }))

        manager.setLanguage(jaLang)
        XCTAssertEqual(manager.effectiveLanguage, jaLang)
        XCTAssertEqual(manager.localized(.syncNow), "今すぐ同期")
    }

    func testAllKeysAreDefinedInBothEnglishAndChinese() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        for key in LocalizedKey.allCases {
            let en = manager.localized(key, language: .en)
            let zh = manager.localized(key, language: .zh)
            XCTAssertFalse(en.isEmpty, "Missing English translation for \(key.rawValue)")
            XCTAssertFalse(zh.isEmpty, "Missing Chinese translation for \(key.rawValue)")
            // Ensure it didn't just return the raw key name
            XCTAssertNotEqual(en, key.rawValue, "English translation seems to be unlocalized key: \(key.rawValue)")
            XCTAssertNotEqual(zh, key.rawValue, "Chinese translation seems to be unlocalized key: \(key.rawValue)")
        }
    }

    func testRedesignCopyIsCompleteAndLocalized() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let requiredKeys: [LocalizedKey] = [
            .dashboardContext, .dashboardContextDescription, .selectedRange,
            .todayFocus, .todayFocusDescription, .topAgent, .tokenComposition,
            .agentUsage, .syncFreshness, .exactValue, .compactTotal,
            .inputLabel, .outputLabel, .cacheLabel, .costLabel, .approxValue,
            .tokenValue, .cacheHitRateValue, .distributionShare,
            .lastSynced, .notSyncedYet, .syncInProgress, .syncFailed,
            .syncedHoursAgo, .syncedOn, .showingCachedData, .staleData,
            .dataUnavailable, .loadingUsage, .loadedUsage, .emptyUsage,
            .errorLoadingUsage, .updatingUsage, .retry, .retrySync, .noDataToDisplay,
            .trendChartSummary, .distributionChartSummary, .chartDataPoint,
            .chartNoData, .chartLegend, .chartAccessibleHint, .heatmapSummary,
            .heatmapDaySummary, .heatmapNoData, .quickGlance,
            .popoverAccessibilityDescription, .popoverNoUsage, .popoverTopAgent,
            .popoverSyncStatus, .openDashboardAction, .openSettingsAction,
            .privacy, .privacyFooter, .privacyLocalOnly, .privacyNoUpload,
            .privacyNoSourceInspection, .privacyUpdateNote, .keyboardShortcuts,
            .keyboardShortcutsDescription, .openSettingsShortcut, .syncNowShortcut,
            .closeSettingsShortcut, .showPopoverShortcut
        ]

        XCTAssertEqual(requiredKeys.count, 64)
        for key in requiredKeys {
            XCTAssertFalse(manager.localized(key, language: .en).isEmpty, "Missing English copy for \(key.rawValue)")
            XCTAssertFalse(manager.localized(key, language: .zh).isEmpty, "Missing Chinese copy for \(key.rawValue)")
        }

        XCTAssertEqual(manager.localized(.dashboardContext, language: .en), "Usage Dashboard")
        XCTAssertEqual(manager.localized(.dashboardContext, language: .zh), "用量看板")
        XCTAssertEqual(manager.localized(.quickGlance, language: .en), "Quick Glance")
        XCTAssertEqual(manager.localized(.quickGlance, language: .zh), "快速概览")
    }

    func testRedesignFormattingUsesLocalizedPlaceholders() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        XCTAssertEqual(
            manager.localized(.selectedRange, language: .en, arguments: "7 Days"),
            "Selected range: 7 Days"
        )
        XCTAssertEqual(
            manager.localized(.selectedRange, language: .zh, arguments: "7天"),
            "所选范围：7天"
        )
        XCTAssertEqual(
            manager.localized(.syncedHoursAgo, language: .en, arguments: 2),
            "Synced 2 hours ago"
        )
        XCTAssertEqual(
            manager.localized(.syncedHoursAgo, language: .zh, arguments: 2),
            "2 小时前同步"
        )
        XCTAssertEqual(
            manager.localized(.chartDataPoint, language: .en, arguments: "10:00", "2.4K", "$0.42"),
            "10:00: 2.4K tokens, $0.42"
        )
        XCTAssertEqual(
            manager.localized(.chartDataPoint, language: .zh, arguments: "10:00", "2.4K", "¥3.02"),
            "10:00：2.4K Token，¥3.02"
        )
        XCTAssertEqual(
            manager.localized(.openSettingsShortcut, language: .en),
            "Open Settings (⌘,)"
        )
        XCTAssertEqual(
            manager.localized(.openSettingsShortcut, language: .zh),
            "打开设置（⌘,）"
        )
    }

    func testSettingsCopyTranslationsAreComplete() {
        let manager = LocalizationManager(userDefaults: testDefaults)

        manager.setLanguage(.en)
        XCTAssertEqual(manager.localized(.agentActive), "Active")
        XCTAssertEqual(manager.localized(.agentNotFound), "Not Found")
        XCTAssertEqual(manager.localized(.agentRecords, arguments: 3), "3 records")
        XCTAssertEqual(manager.localized(.currencySummary), "USD ($) / CNY (¥)")
        XCTAssertEqual(manager.localized(.exchangeRateSummary, arguments: "7.30"), "1 USD = 7.30 CNY")
        XCTAssertEqual(manager.localized(.sqliteDatabase), "SQLite Database")
        XCTAssertEqual(manager.localized(.localFirstPrivate), "100% Local-First & Private")
        XCTAssertTrue(manager.localized(.privacyDescription).contains("never collects"))
        XCTAssertEqual(manager.localized(.openSource), "Open Source")

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.localized(.agentActive), "正常")
        XCTAssertEqual(manager.localized(.agentNotFound), "未找到")
        XCTAssertEqual(manager.localized(.agentRecords, arguments: 3), "3 条记录")
        XCTAssertEqual(manager.localized(.currencySummary), "美元 USD ($) / 人民币 CNY (¥)")
        XCTAssertEqual(manager.localized(.exchangeRateSummary, arguments: "7.30"), "1 USD = 7.30 CNY")
        XCTAssertEqual(manager.localized(.sqliteDatabase), "SQLite 数据库")
        XCTAssertEqual(manager.localized(.localFirstPrivate), "100% 本地优先与隐私保护")
        XCTAssertTrue(manager.localized(.privacyDescription).contains("不会收集"))
        XCTAssertEqual(manager.localized(.openSource), "开源项目")
    }

    func testNewNavigationAndSettingsLocalizationKeysExist() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        let requiredKeys: [LocalizedKey] = [
            .navDashboard,
            .navSettings,
            .agentsConnected,
            .rescanNow,
            .syncedJustNow,
            .syncedMinutesAgo,
            .dataUpdatedJustNow,
            .dataUpdatedMinutesAgo,
            .filterAllAgents,
            .allAgentsUsage,
            .clearFocus,
            .agentHealthSection,
            .pricingSection,
            .storageSection,
            .exchangeRateLabel,
            .preferredCurrencyLabel,
            .revealInFinder,
            .rebuildRollups,
            .clearAllRecords,
            .clearRecordsConfirmTitle,
            .clearRecordsConfirmMessage,
            .rebuildRollupsDescription,
            .clearRecordsDescription,
            .maintenanceSucceeded,
            .maintenanceFailed,
            .autoRefreshLabel,
            .autoRefreshOff,
            .autoRefreshSeconds,
            .storageStatus,
            .generalSettings,
            .usdOption,
            .cnyOption,
            .agentActive,
            .agentNotFound,
            .agentRecords,
            .currencySummary,
            .exchangeRateSummary,
            .exchangeRatePrefix,
            .exchangeRatePlaceholder,
            .currencyCNY,
            .sqliteDatabase,
            .versionLabel,
            .localFirstPrivate,
            .privacyDescription,
            .openSource,
            .github,
            .annualPanorama,
            .annualTotalTokens,
            .annualSpend,
            .annualActiveDays,
            .annualPrimaryAgent,
            .viewAnnualDashboard,
            .viewingAnnualDashboard,
            .exitAnnualDashboard,
            .calendarView,
            .monthlyTrend,
            .moreToolsCount
        ]

        for key in requiredKeys {
            let en = manager.localized(key, language: .en)
            let zh = manager.localized(key, language: .zh)
            XCTAssertFalse(en.isEmpty, "Missing English translation for \(key.rawValue)")
            XCTAssertFalse(zh.isEmpty, "Missing Chinese translation for \(key.rawValue)")
            XCTAssertNotEqual(en, key.rawValue, "English translation seems to be unlocalized key: \(key.rawValue)")
            XCTAssertNotEqual(zh, key.rawValue, "Chinese translation seems to be unlocalized key: \(key.rawValue)")
        }
    }
}
