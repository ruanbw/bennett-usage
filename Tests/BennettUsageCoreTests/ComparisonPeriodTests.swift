import XCTest
@testable import BennettUsageCore

/// Tests for the period-over-period comparison the conclusion band reads.
///
/// The interesting cases are the uninteresting-looking ones: a comparison that
/// cannot be made must say so rather than produce a number, because a wrong
/// percentage is worse than no percentage. Every test here is about a boundary
/// where the honest answer is "not available".
final class ComparisonPeriodTests: XCTestCase {
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

    private func record(
        id: String,
        at date: Date,
        tokens: Int,
        source: String = "omp",
        cacheReadTokens: Int = 0
    ) -> UnifiedTokenRecord {
        UnifiedTokenRecord(
            id: id,
            sourceId: source,
            timestamp: date,
            dayKey: UnifiedTokenRecord.dayKey(for: date),
            sessionKey: "s-\(id)",
            projectFolder: nil,
            model: "m",
            provider: nil,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: cacheReadTokens
        )
    }

    /// The regression that mattered most: the 24-hour range's value comes from a
    /// true rolling window (`fetchPeriodMetrics` aggregates raw records from
    /// `now - 24h`), while its comparison base came from the day-bounded rollup
    /// table over two calendar days — 48 hours. The band therefore compared one
    /// day of usage against two, and read as a roughly two-fold drop.
    func testRollingDayComparesAgainstThePreviousTwentyFourHours() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        // Fixed clock: the window bounds must not depend on when the suite runs.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14, minute: 0))!

        try db.insertRecords([
            // Inside [now - 48h, now - 24h): the previous rolling day.
            record(id: "rolling", at: now.addingTimeInterval(-30 * 3_600), tokens: 1_000),
            // 61 hours back: inside the old two-calendar-day base, outside the
            // real previous 24 hours. This is the record that used to inflate
            // the base.
            record(id: "day-bounded-only", at: now.addingTimeInterval(-61 * 3_600), tokens: 90_000),
            // Inside the current window; must never leak into the base.
            record(id: "current", at: now.addingTimeInterval(-3 * 3_600), tokens: 500_000)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .last24Hours, now: now)

        XCTAssertEqual(comparison.totalTokens, 1_000, "only the previous rolling 24 hours count")
        XCTAssertEqual(comparison.expectedDays, 1)
        XCTAssertEqual(comparison.coveredDays, 1)
        XCTAssertFalse(comparison.isPartialCoverage)
    }

    /// A rolling window with no records states no comparison rather than 0%, and
    /// its cache rate is nil when nothing was cacheable.
    func testRollingDayWithoutRecordsReportsNothing() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14, minute: 0))!

        try db.insertRecords([
            record(id: "current", at: now.addingTimeInterval(-3 * 3_600), tokens: 500_000, cacheReadTokens: 400_000)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .last24Hours, now: now)

        XCTAssertNil(comparison.totalTokens)
        XCTAssertNil(comparison.totalCostUSD)
        XCTAssertNil(comparison.cacheHitRate, "no cache reads means the ratio was never measured")
        XCTAssertEqual(comparison.coveredDays, 0)
        XCTAssertTrue(comparison.hasNoData)
    }

    /// The rolling base reports the same cache ratio the Dashboard band states
    /// for a comparable window: reads over input plus cache traffic.
    func testRollingDayCacheRateMatchesTheBandDefinition() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14, minute: 0))!

        try db.insertRecords([
            record(id: "rolling", at: now.addingTimeInterval(-30 * 3_600), tokens: 100, cacheReadTokens: 900)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .last24Hours, now: now)

        XCTAssertEqual(comparison.cacheHitRate ?? 0, 0.9, accuracy: 0.0001)
    }

    /// "Today so far" must not be compared against a whole yesterday: that
    /// reports a large drop every morning for no reason other than the clock.
    func testTodayComparesAgainstYesterdayUpToTheSameTime() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 9, minute: 0))!
        let yesterdayMorning = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 6, minute: 0))!
        let yesterdayEvening = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 20, minute: 0))!

        try db.insertRecords([
            record(id: "today", at: now.addingTimeInterval(-2 * 3_600), tokens: 1_000),
            record(id: "yesterday-morning", at: yesterdayMorning, tokens: 800),
            // Same calendar day, but after the elapsed point: excluded, otherwise
            // every morning reports a drop that only reflects the hour.
            record(id: "yesterday-evening", at: yesterdayEvening, tokens: 50_000)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .today, now: now)

        XCTAssertEqual(comparison.totalTokens, 800, "yesterday only up to 09:00")
        XCTAssertEqual(comparison.expectedDays, 1)
        XCTAssertEqual(comparison.coveredDays, 1)
    }

    /// The 7- and 30-day comparison windows must abut the range they compare
    /// against. The existing test sampled a day that fell inside both the right
    /// and the wrong window, so it could not see that the code had shifted a day
    /// back: `D-14…D-8` instead of `D-13…D-7`.
    func testWeekComparisonWindowAbutsTheCurrentOne() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12, minute: 0))!
        let startOfToday = calendar.startOfDay(for: now)

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: startOfToday)!
        }

        try db.insertRecords([
            // Inside the 7-day base (D-13…D-7): both edges.
            record(id: "d-7", at: day(-7), tokens: 100),
            record(id: "d-13", at: day(-13), tokens: 200),
            // The day the old window wrongly included, and one day too far back
            // for the base that should have included it.
            record(id: "d-14", at: day(-14), tokens: 7_000),
            // Inside the 30-day base (D-59…D-30): both edges.
            record(id: "d-30", at: day(-30), tokens: 400),
            record(id: "d-59", at: day(-59), tokens: 500),
            // The day the old 30-day window wrongly included.
            record(id: "d-60", at: day(-60), tokens: 9_000),
            // Inside the current window; must never leak into a base.
            record(id: "d-3", at: day(-3), tokens: 50_000)
        ])
        try await aggregator.rebuildDailyRollups()

        let week = try await aggregator.fetchComparisonPeriod(range: .last7Days, now: now)
        XCTAssertEqual(week.totalTokens, 300, "the base is D-13…D-7; D-14 belongs to the window before it")
        XCTAssertEqual(week.expectedDays, 7)
        XCTAssertEqual(week.coveredDays, 2)

        let month = try await aggregator.fetchComparisonPeriod(range: .last30Days, now: now)
        XCTAssertEqual(month.expectedDays, 30)
        XCTAssertEqual(month.totalTokens, 900, "the base is D-59…D-30; D-60 belongs to the window before it")
        XCTAssertEqual(month.coveredDays, 2)
    }

    func testTodayComparesAgainstYesterday() async throws {
        try db.insertRecords([
            record(id: "today", dayOffset: 0, tokens: 1_000),
            record(id: "yesterday", dayOffset: -1, tokens: 500)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .today)

        XCTAssertEqual(comparison.totalTokens, 500, "today's comparison window is yesterday")
        XCTAssertEqual(comparison.coveredDays, 1)
        XCTAssertEqual(comparison.expectedDays, 1)
        XCTAssertFalse(comparison.isPartialCoverage)
    }

    /// The headline regression: a window with no records must not report a
    /// number, because every percentage derived from it would be a lie.
    func testNoComparisonDataReturnsNilRatherThanZero() async throws {
        try db.insertRecords([record(id: "today", dayOffset: 0, tokens: 1_000)])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .today)

        XCTAssertNil(comparison.totalTokens)
        XCTAssertNil(comparison.totalCostUSD)
        XCTAssertTrue(comparison.hasNoData)
    }

    /// A 30-day comparison over a three-day history is a missing-history
    /// problem, not a 90% drop. The window knows how much of itself the
    /// database actually covers so the UI can say so.
    func testPartialCoverageIsReportedNotHidden() async throws {
        try db.insertRecords([record(id: "old", dayOffset: -40, tokens: 1_000)])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .last30Days)

        XCTAssertTrue(comparison.isPartialCoverage)
        XCTAssertEqual(comparison.coveredDays, 1)
        XCTAssertEqual(comparison.expectedDays, 30)
    }

    func testLastSevenDaysComparesAgainstThePrecedingWeekNotOverlapping() async throws {
        // One record inside each window, at opposite ends of the 14-day span.
        try db.insertRecords([
            record(id: "recent", dayOffset: -2, tokens: 4_000),
            record(id: "prior", dayOffset: -10, tokens: 1_000)
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .last7Days)

        XCTAssertEqual(comparison.totalTokens, 1_000, "only the preceding week counts")
        XCTAssertEqual(comparison.expectedDays, 7)
    }

    func testToolFilterIsHonouredByTheComparisonWindow() async throws {
        try db.insertRecords([
            record(id: "omp-yesterday", dayOffset: -1, tokens: 700, source: "omp"),
            record(id: "claude-yesterday", dayOffset: -1, tokens: 9_000, source: "claude")
        ])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .today, toolFilter: "omp")

        XCTAssertEqual(comparison.totalTokens, 700)
    }

    /// A year view has no equal-length predecessor that shares its boundary
    /// semantics, so it reports no comparison instead of comparing this year
    /// against a partial one.
    func testYearViewsHaveNoComparablePeriod() async throws {
        for range in [TimeRangeOption.pastYear, .year(2026)] {
            let comparison = try await aggregator.fetchComparisonPeriod(range: range)
            XCTAssertNil(comparison.totalTokens, "\(range) must not report a delta")
            XCTAssertEqual(comparison.expectedDays, 0)
        }
    }

    func testCacheHitRateIsNilWhenNoCacheableTokens() async throws {
        try db.insertRecords([record(id: "yesterday", dayOffset: -1, tokens: 1_000)])
        try await aggregator.rebuildDailyRollups()

        let comparison = try await aggregator.fetchComparisonPeriod(range: .today)

        XCTAssertNil(comparison.cacheHitRate, "a 0% hit rate and an unmeasured one are different claims")
    }
}
