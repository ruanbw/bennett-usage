import XCTest
import SwiftUI
import AppKit
@testable import BennettUsageCore

final class ThemeColorsTests: XCTestCase {

    func testThemeModeCasesAndDefault() {
        XCTAssertEqual(AppThemeMode.allCases.map(\.rawValue), ["system", "dark", "light"])
        XCTAssertEqual(AppThemeMode.defaultMode, .dark)
        XCTAssertEqual(AppThemeMode.storageKey, "bennett_theme_mode")
        XCTAssertEqual(AppThemeMode.userDefaultsKey, AppThemeMode.storageKey)
        XCTAssertEqual(AppThemeMode.allCases.map(\.id), ["system", "dark", "light"])
        XCTAssertEqual(AppThemeMode.system.titleKey, "theme.system")
        XCTAssertEqual(AppThemeMode.dark.titleKey, "theme.dark")
        XCTAssertEqual(AppThemeMode.light.titleKey, "theme.light")
    }

    func testThemeModeAppearanceAndLocalizedTitles() {
        let suiteName = "ThemeModeAppearanceTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localization = LocalizationManager(userDefaults: defaults)

        XCTAssertNil(AppThemeMode.system.colorScheme)
        XCTAssertNil(AppThemeMode.system.appearance)
        XCTAssertEqual(AppThemeMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppThemeMode.dark.appearance?.name, NSAppearance.Name.darkAqua)
        XCTAssertEqual(AppThemeMode.light.colorScheme, .light)
        XCTAssertEqual(AppThemeMode.light.appearance?.name, NSAppearance.Name.aqua)

        localization.setLanguage(.en)
        XCTAssertEqual(AppThemeMode.system.localizedTitle(localization: localization), "Follow System")
        XCTAssertEqual(AppThemeMode.dark.localizedTitle(localization: localization), "Dark")
        localization.setLanguage(.zh)
        XCTAssertEqual(AppThemeMode.system.localizedTitle(localization: localization), "跟随系统")
        XCTAssertEqual(AppThemeMode.light.localizedTitle(localization: localization), "浅色")
    }

    func testThemeModePersistenceFallsBackToDark() {
        let suiteName = "ThemeColorsTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppThemeMode.stored(in: defaults), .dark)
        defaults.set(AppThemeMode.light.rawValue, forKey: AppThemeMode.storageKey)
        XCTAssertEqual(AppThemeMode.stored(in: defaults), .light)

        defaults.set("not-a-theme", forKey: AppThemeMode.storageKey)
        XCTAssertEqual(AppThemeMode.stored(in: defaults), .dark)
    }

    func testDynamicColorResolvesAppearance() {
        let dynamicColor = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#000000")
        XCTAssertNotNil(dynamicColor)

        let aquaAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        let lightNS = NSColor(hex: "#FFFFFF")
        let darkNS = NSColor(hex: "#000000")
        let dynamicNS = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkNS : lightNS
        })

        aquaAppearance.performAsCurrentDrawingAppearance {
            let color = dynamicNS.usingColorSpace(.sRGB)
            XCTAssertEqual(color?.redComponent ?? 0, 1.0, accuracy: 0.01)
        }

        darkAppearance.performAsCurrentDrawingAppearance {
            let color = dynamicNS.usingColorSpace(.sRGB)
            XCTAssertEqual(color?.redComponent ?? 1, 0.0, accuracy: 0.01)
        }
    }

    func testAllEighteenAgentsHaveDistinctBrandColors() {
        let agentIds = [
            "claude", "cursor", "codex", "gemini", "copilot",
            "trae", "dsh", "pi", "omp", "cline", "roo", "qwen",
            "opencode", "antigravity", "continue", "goose", "crush", "kimi"
        ]

        XCTAssertEqual(agentIds.count, 18)
        for agentId in agentIds {
            let color = AppTheme.Agent.knownColor(for: agentId)
            XCTAssertNotNil(color, "Missing color for agent \(agentId)")
            XCTAssertNotNil(AppTheme.Agent.allMap[agentId], "Missing color in allMap for agent \(agentId)")
        }

        // Palette lookup via ChartPalette should return exact colors
        let paletteColors = ChartPalette.shared.colors(for: agentIds)
        XCTAssertEqual(paletteColors.count, 18)
        for agentId in agentIds {
            XCTAssertNotNil(paletteColors[agentId])
        }
    }

    func testInferredModelColors() {
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "claude-3-5-sonnet-20241022"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "gpt-4o"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "o1-preview"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "o3-mini"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "gemini-1.5-pro"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "deepseek-chat"))
        XCTAssertNotNil(AppTheme.Agent.inferredModelColor(for: "qwen-2.5-coder"))
        XCTAssertNil(AppTheme.Agent.inferredModelColor(for: "custom-local-model"))
    }

    func testTertiaryTextMeetsWCAGContrastOnPrimarySurface() throws {
        let aquaAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let lightContrast = wcagContrastRatio(
            AppTheme.Text.tertiary,
            against: AppTheme.Surface.primary,
            appearance: aquaAppearance
        )
        let darkContrast = wcagContrastRatio(
            AppTheme.Text.tertiary,
            against: AppTheme.Surface.primary,
            appearance: darkAppearance
        )

        XCTAssertGreaterThanOrEqual(lightContrast, 4.5, "Light tertiary contrast: \(lightContrast)")
        XCTAssertGreaterThanOrEqual(darkContrast, 4.5, "Dark tertiary contrast: \(darkContrast)")
    }

    private func wcagContrastRatio(
        _ foreground: Color,
        against background: Color,
        appearance: NSAppearance
    ) -> CGFloat {
        let foregroundLuminance = wcagRelativeLuminance(foreground, appearance: appearance)
        let backgroundLuminance = wcagRelativeLuminance(background, appearance: appearance)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func wcagRelativeLuminance(_ color: Color, appearance: NSAppearance) -> CGFloat {
        var components: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let srgb = NSColor(color).usingColorSpace(.sRGB)
            components = (srgb?.redComponent ?? 0, srgb?.greenComponent ?? 0, srgb?.blueComponent ?? 0)
        }

        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linearize(components.0)
        let green = linearize(components.1)
        let blue = linearize(components.2)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func testHeatmapFiveLevelScale() {
        let level0 = AppTheme.Heatmap.color(for: 0)
        let level1 = AppTheme.Heatmap.color(for: 1)
        let level2 = AppTheme.Heatmap.color(for: 2)
        let level3 = AppTheme.Heatmap.color(for: 3)
        let level4 = AppTheme.Heatmap.color(for: 4)

        XCTAssertNotNil(level0)
        XCTAssertNotNil(level1)
        XCTAssertNotNil(level2)
        XCTAssertNotNil(level3)
        XCTAssertNotNil(level4)
    }

    func testHarmonicPaletteDeterminism() {
        let color1 = AppTheme.Harmonic.color(for: "custom-model-abc")
        let color2 = AppTheme.Harmonic.color(for: "custom-model-abc")
        XCTAssertNotNil(color1)
        XCTAssertNotNil(color2)
    }

    func testRankColors() {
        XCTAssertNotNil(AppTheme.Rank.color(for: 1))
        XCTAssertNotNil(AppTheme.Rank.color(for: 2))
        XCTAssertNotNil(AppTheme.Rank.color(for: 3))
        XCTAssertNotNil(AppTheme.Rank.color(for: 4))
    }
}
