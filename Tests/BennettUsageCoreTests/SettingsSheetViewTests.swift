import XCTest
import SwiftUI
@testable import BennettUsageCore

final class SettingsSheetViewTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsSheetViewTests_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testSettingsSheetViewInitialization() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        var dismissed = false
        let view = SettingsSheetView(localization: manager) {
            dismissed = true
        }

        XCTAssertNotNil(view.body)
        view.onDismiss()
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testLanguageSwitchingInSettingsSheet() {
        let manager = LocalizationManager(userDefaults: testDefaults)
        XCTAssertEqual(manager.selectedLanguage, .system)

        let view = SettingsSheetView(localization: manager, onDismiss: {})
        XCTAssertNotNil(view)

        manager.setLanguage(.zh)
        XCTAssertEqual(manager.selectedLanguage, .zh)
        XCTAssertEqual(manager.localized(.settings), "设置")

        manager.setLanguage(.en)
        XCTAssertEqual(manager.selectedLanguage, .en)
        XCTAssertEqual(manager.localized(.settings), "Settings")
    }
}
