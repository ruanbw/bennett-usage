import XCTest
@testable import BennettUsageCore

/// Tests for the conclusion band's coverage fraction.
///
/// The fraction is only honest when both halves describe the same window. It
/// used to read `34 / 1` for the 24-hour view and `34 / 30` for the 30-day view,
/// because the numerator counted days from the annual heatmap while the
/// denominator counted days in the selected range — a number that looked
/// plausible and meant nothing.
final class RangeCoverageTests: XCTestCase {
    private var db: DatabaseManager!
    private var aggregator: MetricsAggregator!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
        aggregator = MetricsAggregator(database: db)
    }

    private func record(
        id: String,
        dayOffset: Int,
        tokens: Int,
        source: String = "omp"
    ) -> UnifiedTokenRecord {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(dayOffset * 86_400))
        return UnifiedTokenRecord(
            id: id,
            sourceId: source,
            timestamp: day,
            dayKey: UnifiedTokenRecord.dayKey(for: day),
            sessionKey: "s-\(id)",
            projectFolder: nil,
            model: "m",
            provider: nil,
            inputTokens: tokens,
            outputTokens: 0
        )
    }

    /// The regression: history deeper than the window must not inflate the
    /// numerator. 34 recorded days under a 30-day window is a full window, not
    /// a fraction whose top is bigger than its bottom.
    func testNumeratorNeverExceedsTheWindow() async throws {
        try db.insertRecords(
            (0..<40).map { offset in
                record(id: "d\(offset)", dayOffset: -offset, tokens: 100)
            }
        )
        try await aggregator.rebuildDailyRollups()

        let coverage = try await aggregator.fetchRangeCoverage(range: .last30Days)

        XCTAssertEqual(coverage.expectedDays, 30)
        XCTAssertEqual(coverage.recordedDays, 30, "40 days of history still covers a 30-day window completely")
        XCTAssertEqual(coverage.fraction, 1.0)
        XCTAssertFalse(coverage.isPartial)
    }

    /// The historical bug, stated as a test: a one-day window cannot report
    /// dozens of covered days.
    func testOneDayWindowReportsAtMostOneDay() async throws {
        try db.insertRecords(
            (0..<10).map { offset in
                record(id: "d\(offset)", dayOffset: -offset, tokens: 100)
            }
        )
        try await aggregator.rebuildDailyRollups()

        let today = try await aggregator.fetchRangeCoverage(range: .today)
        XCTAssertEqual(today.recordedDays, 1)
        XCTAssertEqual(today.expectedDays, 1)

        // `.last24Hours` is a rolling window that can graze two calendar days,
        // so the numerator is capped rather than left to exceed the window.
        let rolling = try await aggregator.fetchRangeCoverage(range: .last24Hours)
        XCTAssertEqual(rolling.recordedDays, 1)
        XCTAssertEqual(rolling.expectedDays, 1)
        XCTAssertEqual(rolling.fraction, 1.0)
    }

    /// A short history under a wide window is reported as partial, with the
    /// real day count — the case the metric exists for.
    func testShortHistoryUnderWideWindowIsPartial() async throws {
        try db.insertRecords([
            record(id: "d0", dayOffset: 0, tokens: 100),
            record(id: "d1", dayOffset: -3, tokens: 100),
            record(id: "d2", dayOffset: -9, tokens: 100)
        ])
        try await aggregator.rebuildDailyRollups()

        let coverage = try await aggregator.fetchRangeCoverage(range: .last30Days)

        XCTAssertEqual(coverage.recordedDays, 3)
        XCTAssertEqual(coverage.expectedDays, 30)
        XCTAssertTrue(coverage.isPartial)
    }

    func testEmptyWindowReportsZeroRecordedDays() async throws {
        let coverage = try await aggregator.fetchRangeCoverage(range: .today)

        XCTAssertEqual(coverage.recordedDays, 0)
        XCTAssertEqual(coverage.expectedDays, 1)
        XCTAssertEqual(coverage.fraction, 0)
        XCTAssertFalse(coverage.isPartial, "no data is empty, not partial")
    }

    func testToolFilterScopesTheCoveredDays() async throws {
        try db.insertRecords([
            record(id: "a", dayOffset: 0, tokens: 100, source: "omp"),
            record(id: "b", dayOffset: -1, tokens: 100, source: "claude"),
            record(id: "c", dayOffset: -2, tokens: 100, source: "claude")
        ])
        try await aggregator.rebuildDailyRollups()

        let all = try await aggregator.fetchRangeCoverage(range: .last7Days)
        XCTAssertEqual(all.recordedDays, 3)

        let omp = try await aggregator.fetchRangeCoverage(range: .last7Days, toolFilter: "omp")
        XCTAssertEqual(omp.recordedDays, 1, "days outside the filter are not coverage")
    }

    /// A year window spans the whole year even in January, and leap years are
    /// laid out honestly rather than rounded to 365.
    func testYearWindowSpansTheWholeYear() async throws {
        let common = try await aggregator.fetchRangeCoverage(range: .year(2026))
        XCTAssertEqual(common.expectedDays, 365)

        let leap = try await aggregator.fetchRangeCoverage(range: .year(2028))
        XCTAssertEqual(leap.expectedDays, 366)
    }

    func testRollingYearSpansThreeHundredSixtyFiveOrSixDays() async throws {
        let coverage = try await aggregator.fetchRangeCoverage(range: .pastYear)

        XCTAssertTrue(
            [365, 366].contains(coverage.expectedDays),
            "a rolling year is 365 or 366 days, got \(coverage.expectedDays)"
        )
        XCTAssertEqual(coverage.recordedDays, 0)
    }
}
