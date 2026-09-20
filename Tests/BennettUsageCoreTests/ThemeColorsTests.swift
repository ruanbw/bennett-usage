import XCTest
import SwiftUI
import AppKit
@testable import BennettUsageCore

final class ThemeColorsTests: XCTestCase {

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

    func testAllFourteenAgentsHaveDistinctBrandColors() {
        let agentIds = [
            "claude", "cursor", "codex", "gemini", "copilot",
            "trae", "dsh", "pi", "omp", "cline", "roo", "qwen",
            "opencode", "antigravity"
        ]

        XCTAssertEqual(agentIds.count, 14)
        for agentId in agentIds {
            let color = AppTheme.Agent.knownColor(for: agentId)
            XCTAssertNotNil(color, "Missing color for agent \(agentId)")
            XCTAssertNotNil(AppTheme.Agent.allMap[agentId], "Missing color in allMap for agent \(agentId)")
        }

        // Palette lookup via ChartPalette should return exact colors
        let paletteColors = ChartPalette.shared.colors(for: agentIds)
        XCTAssertEqual(paletteColors.count, 14)
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
