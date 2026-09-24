import XCTest
import SwiftUI
@testable import BennettUsageCore

final class HeatmapGridViewTests: XCTestCase {
    @MainActor
    func testHeatmapGridWeekChunking() {
        var cells: [HeatmapDayCell] = []
        let calendar = Calendar.current
        var start = calendar.startOfDay(for: Date())
        // Start exactly on the calendar's first weekday so the first week has
        // no leading placeholders: 14 consecutive days must fill 2 full weeks.
        while calendar.component(.weekday, from: start) != calendar.firstWeekday {
            start = calendar.date(byAdding: .day, value: 1, to: start)!
        }
        for i in 0..<14 {
            cells.append(HeatmapDayCell(
                date: calendar.date(byAdding: .day, value: i, to: start)!,
                dayKey: String(format: "2026-01-%02d", i + 1),
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
        XCTAssertTrue(view.weeks[0].allSatisfy { $0 != nil })
        XCTAssertEqual(view.weeks[0].compactMap(\.self).first?.dayKey, "2026-01-01")
    }

    @MainActor
    func testHeatmapGridWeekLeadingPlaceholderAlignment() {
        // Days starting mid-week must be padded with nil placeholders so the
        // same weekday always lands in the same row across the grid. Pinned to
        // fixed dates: weekStart is the firstWeekday on/before 2026-01-01, and
        // cells begin 3 days into that week — leading = 3 for any firstWeekday.
        let calendar = Calendar.current
        let jan1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let back = ((calendar.component(.weekday, from: jan1) - calendar.firstWeekday) % 7 + 7) % 7
        let weekStart = calendar.date(byAdding: .day, value: -back, to: jan1)!
        let start = calendar.date(byAdding: .day, value: 3, to: weekStart)!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let cells = (0..<3).map { i -> HeatmapDayCell in
            let date = calendar.date(byAdding: .day, value: i, to: start)!
            return HeatmapDayCell(
                date: date,
                dayKey: formatter.string(from: date),
                totalTokens: i * 100,
                costUSD: Double(i) * 0.01,
                intensityLevel: i % 5,
                toolBreakdown: ["omp": i * 100]
            )
        }

        let view = HeatmapGridView(cells: cells)
        XCTAssertEqual(view.weeks.count, 1)
        let firstWeek = view.weeks[0]
        XCTAssertEqual(firstWeek.count, 7)
        XCTAssertEqual(firstWeek[..<3].allSatisfy { $0 == nil }, true)
        XCTAssertEqual(firstWeek[3]?.dayKey, formatter.string(from: start))
        XCTAssertEqual(firstWeek[5]?.dayKey, formatter.string(from: calendar.date(byAdding: .day, value: 2, to: start)!))
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

        // Verify generated palette colors are distinct and session-stable
        let palette = ChartPalette(seed: 0.42)
        let colors = palette.colors(for: ["pi", "omp", "claude", "codex", "gemini"])
        XCTAssertNotEqual(colors["pi"], colors["omp"])
        XCTAssertNotEqual(colors["claude"], colors["codex"])
        XCTAssertEqual(palette.colors(for: ["pi", "omp", "claude", "codex", "gemini"]), colors)

        // The filter bar colors come from a fixed all-agents universe, so a tool
        // keeps one color while the range-scoped pill list grows and shrinks.
        XCTAssertEqual(AgentFilterBarView.knownAgentIds.count, 15)
        XCTAssertEqual(Set(AgentFilterBarView.knownAgentIds).count, 15)
        XCTAssertTrue(AgentFilterBarView.knownAgentIds.contains("continue"))
        XCTAssertTrue(AgentFilterBarView.knownAgentIds.contains("cline"))
        for agentId in AgentFilterBarView.knownAgentIds {
            XCTAssertNotNil(AgentFilterBarView.colorMap[agentId], "missing palette color for '\(agentId)'")
        }
        XCTAssertEqual(AgentFilterBarView.colorMap, AgentFilterBarView.colorMap)

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
    func testAgentFilterBarViewMinimalistState() throws {
        var selected: String? = nil
        let view = AgentFilterBarView(
            selectedAgent: selected,
            availableAgents: ["claude", "cursor", "codex"],
            localization: .shared
        ) { agent in
            selected = agent
        }
        XCTAssertNotNil(view)
        XCTAssertEqual(AgentFilterBarView.displayName(for: "claude"), "Claude Code")
        XCTAssertNotNil(AgentFilterBarView.colorMap["claude"])
    }

    @MainActor
    func testHeatmapDayAccessibilityValue() {
        let defaults = UserDefaults(suiteName: "HeatmapGridViewAccessibilityTests_\(UUID().uuidString)")!
        let localization = LocalizationManager(userDefaults: defaults)
        localization.setLanguage(.en)

        let active = HeatmapDayCell(
            date: Date(),
            dayKey: "2026-09-01",
            totalTokens: 500,
            costUSD: 0.05,
            intensityLevel: 2,
            toolBreakdown: ["pi": 500]
        )
        XCTAssertEqual(
            HeatmapGridView.accessibilityValue(for: active, localization: localization),
            "Total Tokens: 500 (500) · Cost: $0.050"
        )

        let empty = HeatmapDayCell(
            date: Date(),
            dayKey: "2026-09-02",
            totalTokens: 0,
            costUSD: 0,
            intensityLevel: 0,
            toolBreakdown: [:]
        )
        XCTAssertEqual(
            HeatmapGridView.accessibilityValue(for: empty, localization: localization),
            "No token usage"
        )
    }

    @MainActor
    func testHeatmapDaySelectedAccessibilityTrait() {
        XCTAssertTrue(HeatmapGridView.accessibilityTraits(isSelected: true).contains(.isSelected))
        XCTAssertFalse(HeatmapGridView.accessibilityTraits(isSelected: false).contains(.isSelected))
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
