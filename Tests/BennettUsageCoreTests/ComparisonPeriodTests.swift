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
