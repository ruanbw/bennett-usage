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

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.localized(.appName), "Bennett Usage")
        XCTAssertEqual(manager.localized(.syncNow), "立即同步")
        XCTAssertEqual(manager.localized(.todaysTokens), "今日 Token")
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
        }
    }
}
