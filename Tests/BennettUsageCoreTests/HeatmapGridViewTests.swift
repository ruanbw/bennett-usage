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
}
