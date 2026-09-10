import XCTest
@testable import BennettUsageCore

final class HeatmapGridViewTests: XCTestCase {
    @MainActor
    func testHeatmapGridWeekChunking() {
        var cells: [HeatmapDayCell] = []
        let now = Date()
        for i in 0..<14 {
            cells.append(HeatmapDayCell(
                date: now,
                dayKey: "2026-01-\(i + 1)",
                totalTokens: i * 100,
                costUSD: Double(i) * 0.01,
                intensityLevel: i % 5,
                toolBreakdown: ["omp": i * 100]
            ))
        }

        let view = HeatmapGridView(cells: cells)
        XCTAssertEqual(view.weeks.count, 2)
        XCTAssertEqual(view.weeks[0].count, 7)
        XCTAssertEqual(view.weeks[1].count, 7)
    }

    @MainActor
    func testHeatmapGridViewWithLocalization() {
        let defaults = UserDefaults(suiteName: "HeatmapGridViewTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        localization.setLanguage(.zh)

        let view = HeatmapGridView(cells: [], localization: localization)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testAgentFilterBarViewAllAndIndividualSelection() {
        let defaults = UserDefaults(suiteName: "AgentFilterBarTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        var lastSelected: String?? = .none // .none = not called, .some(nil) = All, .some("x") = agent

        // All Agents selected (selectedAgent == nil)
        let allView = AgentFilterBarView(
            selectedAgent: nil,
            availableAgents: ["pi", "omp", "claude", "codex"],
            localization: localization,
            onSelect: { lastSelected = .some($0) }
        )
        XCTAssertNotNil(allView.body)

        // Verify display name and color helpers
        XCTAssertEqual(AgentFilterBarView.displayName(for: "pi"), "Pi Agent")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "omp"), "Oh My Pi")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "claude"), "Claude Code")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "codex"), "OpenAI Codex")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "unknown"), "Unknown")

        // Verify brand colors are distinct
        let piColor = AgentFilterBarView.brandColor(for: "pi")
        let ompColor = AgentFilterBarView.brandColor(for: "omp")
        XCTAssertNotEqual(piColor, ompColor)

        // Individual agent selected
        let piView = AgentFilterBarView(
            selectedAgent: "pi",
            availableAgents: ["pi", "omp"],
            localization: localization,
            onSelect: { lastSelected = .some($0) }
        )
        XCTAssertNotNil(piView.body)

        // Trigger onSelect callback
        piView.onSelect("claude")
        XCTAssertEqual(lastSelected, .some("claude"))

        piView.onSelect(Optional<String>.none)
        XCTAssertEqual(lastSelected, .some(Optional<String>.none))
    }

    @MainActor
    func testHeatmapGridSelectionHighlight() {
        let cells = [
            HeatmapDayCell(
                date: Date(),
                dayKey: "2026-09-01",
                totalTokens: 500,
                costUSD: 0.05,
                intensityLevel: 2,
                toolBreakdown: ["pi": 500]
            ),
            HeatmapDayCell(
                date: Date(),
                dayKey: "2026-09-02",
                totalTokens: 300,
                costUSD: 0.03,
                intensityLevel: 1,
                toolBreakdown: ["omp": 300]
            )
        ]

        // Without selection
        let viewNoSelection = HeatmapGridView(cells: cells)
        XCTAssertNotNil(viewNoSelection.body)

        // With selection
        let viewWithSelection = HeatmapGridView(cells: cells, selectedDayKey: "2026-09-01")
        XCTAssertNotNil(viewWithSelection.body)
    }
}
