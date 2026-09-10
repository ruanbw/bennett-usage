import XCTest
import SwiftUI
@testable import BennettUsageCore

final class DashboardViewTests: XCTestCase {
    @MainActor
    func testDashboardViewInitialization() throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)

        let view = DashboardView(aggregator: aggregator)
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func testDashboardViewWithData() async throws {
        let db = try DatabaseManager.inMemory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let record = UnifiedTokenRecord(
            id: "rec-1",
            sourceId: "claude",
            timestamp: Date(),
            dayKey: todayKey,
            sessionKey: "session-1",
            projectFolder: "/test",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 5000,
            outputTokens: 1000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.03
        )
        try db.insertRecords([record])

        let aggregator = MetricsAggregator(database: db)
        let view = DashboardView(aggregator: aggregator)
        XCTAssertNotNil(view.body)
    }
}
