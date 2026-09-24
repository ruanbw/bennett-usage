import XCTest
@testable import BennettUsageCore

final class DashboardUIStateTests: XCTestCase {
    // MARK: - Reusable presentation contracts

    func testDashboardLoadStateDescriptions() {
        let expected: [DashboardLoadState: String] = [
            .loading: "Loading usage",
            .loaded: "Usage loaded",
            .empty: "No usage yet",
            .stale: "Showing cached usage",
            .error: "Usage could not be loaded",
            .updating: "Updating usage"
        ]

        XCTAssertEqual(DashboardLoadState.allCases.count, expected.count)
        for state in DashboardLoadState.allCases {
            XCTAssertEqual(state.description, expected[state])
            XCTAssertEqual(DashboardUIState.Phase(rawValue: state.rawValue), state)
        }
    }

    func testLastSuccessfulRefreshRetainsItsCompletionDate() {
        let date = makeDate(2026, 9, 24, 12, 0)
        let refresh = LastSuccessfulRefresh(completedAt: date)

        XCTAssertEqual(refresh.completedAt, date)
    }

    func testSyncFreshnessModelStoresCallerSuppliedFactsAndNormalizesFailureCopy() {
        let checked = makeDate(2026, 9, 24, 12, 1)
        let completed = makeDate(2026, 9, 24, 12, 0)
        let refresh = LastSuccessfulRefresh(completedAt: completed)
        let model = SyncFreshnessModel(
            lastChecked: checked,
            lastSuccessful: refresh,
            isRefreshing: false,
            partialFailure: "  Claude was unavailable.  "
        )

        XCTAssertEqual(model.lastChecked, checked)
        XCTAssertEqual(model.lastSuccessful, refresh)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.partialFailure, "Claude was unavailable.")
        XCTAssertTrue(model.hasSuccessfulRefresh)
    }

    func testSyncFreshnessModelDoesNotPromotePartialFailureToSuccess() {
        let checked = makeDate(2026, 9, 24, 12, 1)
        let model = SyncFreshnessModel(
            lastChecked: checked,
            lastSuccessful: nil,
            isRefreshing: false,
            partialFailure: "One adapter failed"
        )

        XCTAssertEqual(model.lastChecked, checked)
        XCTAssertNil(model.lastSuccessful)
        XCTAssertFalse(model.hasSuccessfulRefresh)
        XCTAssertEqual(model.lastSuccessfulDescription(relativeTo: checked), "Not synced yet")
    }

    func testUnknownSyncFreshnessHasNoClaims() {
        let model = SyncFreshnessModel.unknown

        XCTAssertNil(model.lastChecked)
        XCTAssertNil(model.lastSuccessful)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.partialFailure)
        XCTAssertFalse(model.hasSuccessfulRefresh)
        XCTAssertEqual(model, SyncFreshnessModel())
    }

    func testSyncFreshnessNormalizesBlankPartialFailureToNil() {
        let model = SyncFreshnessModel(partialFailure: " \n\t ")

        XCTAssertNil(model.partialFailure)
    }

    func testQuickGlanceSnapshotCarriesSummaryOptionalTodayTrendAndFreshness() {
        let summary = makeToday(tokens: 1_250)
        let today = [
            TrendPoint(label: "9 AM", tokens: 500, costUSD: 0.10),
            TrendPoint(label: "10 AM", tokens: 750, costUSD: 0.15)
        ]
        let freshness = SyncFreshnessModel(
            lastChecked: makeDate(2026, 9, 24, 12, 0),
            lastSuccessful: LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 11, 59)),
            isRefreshing: true,
            partialFailure: "Codex was unavailable"
        )

        let snapshot = QuickGlanceSnapshot(
            summary: summary,
            today: today,
            freshness: freshness
        )

        XCTAssertEqual(snapshot.summary, summary)
        XCTAssertEqual(snapshot.today, today)
        XCTAssertEqual(snapshot.freshness, freshness)
        XCTAssertTrue(snapshot.hasUsage)
    }

    func testQuickGlanceSnapshotDistinguishesMissingFromEmptyTodayTrend() {
        let summary = makeToday(tokens: 0)
        let withoutTrend = QuickGlanceSnapshot(summary: summary)
        let withEmptyTrend = QuickGlanceSnapshot(summary: summary, today: [])

        XCTAssertNil(withoutTrend.today)
        XCTAssertEqual(withEmptyTrend.today, [])
        XCTAssertEqual(withoutTrend.freshness, .unknown)
        XCTAssertFalse(withoutTrend.hasUsage)
    }

    // MARK: - Dashboard state transitions

    func testInitialStateIsLoadingWithoutSnapshotOrTransientCopy() {
        let state = DashboardUIState()

        XCTAssertEqual(state.phase, .loading)
        XCTAssertNil(state.periodMetrics)
        XCTAssertNil(state.todaySummary)
        XCTAssertEqual(state.freshness, .unknown)
        XCTAssertNil(state.lastSuccessfulRefresh)
        XCTAssertNil(state.lastSuccessfulSync)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertFalse(state.hasUsage)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.canRetry)
    }

    func testSuccessfulAnalyticsLoadDoesNotInventSuccessfulSyncFreshness() {
        var state = DashboardUIState()

        state.loadSucceeded(periodMetrics: makeMetrics(tokens: 500))

        XCTAssertEqual(state.phase, .loaded)
        XCTAssertTrue(state.hasSnapshot)
        XCTAssertNil(state.freshness.lastChecked)
        XCTAssertNil(state.lastSuccessfulRefresh)
        XCTAssertNil(state.lastSuccessfulSync)
    }

    func testSuccessfulLoadPublishesLoadedSnapshotAndPreservesKnownFreshness() {
        let metrics = makeMetrics(tokens: 500)
        let today = makeToday(tokens: 125)
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 12, 0))
        let freshness = SyncFreshnessModel(
            lastChecked: refresh.completedAt,
            lastSuccessful: refresh
        )
        var state = DashboardUIState(freshness: freshness)

        state.loadSucceeded(
            periodMetrics: metrics,
            todaySummary: today
        )

        XCTAssertEqual(state.phase, .loaded)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.todaySummary, today)
        XCTAssertEqual(state.freshness, freshness)
        XCTAssertEqual(state.lastSuccessfulRefresh, refresh)
        XCTAssertEqual(state.lastSuccessfulSync, refresh.completedAt)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
        XCTAssertTrue(state.hasUsage)
        XCTAssertFalse(state.isBusy)
    }

    func testSuccessfulZeroTokenLoadIsEmptyButStillASuccessfulAnalyticsSnapshot() {
        let metrics = makeMetrics(tokens: 0)
        let today = makeToday(tokens: 0)
        var state = DashboardUIState()

        state.loadSucceeded(
            periodMetrics: metrics,
            todaySummary: today
        )

        XCTAssertEqual(state.phase, .empty)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.todaySummary, today)
        XCTAssertTrue(state.hasSnapshot)
        XCTAssertFalse(state.hasUsage)
    }

    func testUpdatingRetainsSnapshotAndSyncFactsUntilSuccessfulRefresh() {
        let originalMetrics = makeMetrics(tokens: 300)
        let today = makeToday(tokens: 100)
        let firstRefresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 10, 0))
        let secondRefresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 12, 0))
        var freshness = SyncFreshnessModel(
            lastChecked: firstRefresh.completedAt,
            lastSuccessful: firstRefresh
        )
        var state = DashboardUIState(freshness: freshness)
        state.loadSucceeded(
            periodMetrics: originalMetrics,
            todaySummary: today
        )
        state.loadFailed(
            errorDescription: "A refresh failed.",
            retryDescription: "Try Again"
        )

        state.beginUpdating()

        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.periodMetrics, originalMetrics)
        XCTAssertEqual(state.todaySummary, today)
        XCTAssertEqual(state.freshness, freshness)
        XCTAssertEqual(state.lastSuccessfulSync, firstRefresh.completedAt)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.canRetry)

        let refreshedMetrics = makeMetrics(tokens: 450)
        freshness = SyncFreshnessModel(
            lastChecked: secondRefresh.completedAt,
            lastSuccessful: secondRefresh
        )
        state.updateFreshness(freshness)
        state.loadSucceeded(periodMetrics: refreshedMetrics)

        XCTAssertEqual(state.phase, .loaded)
        XCTAssertEqual(state.periodMetrics, refreshedMetrics)
        XCTAssertEqual(state.todaySummary, today, "Omitting today data must not erase the existing snapshot")
        XCTAssertEqual(state.lastSuccessfulSync, secondRefresh.completedAt)
    }

    func testFailedRefreshWithSnapshotBecomesStaleAndKeepsLastGoodData() {
        let metrics = makeMetrics(tokens: 700)
        let today = makeToday(tokens: 200)
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 11, 30))
        var state = DashboardUIState(freshness: SyncFreshnessModel(lastSuccessful: refresh))
        state.loadSucceeded(
            periodMetrics: metrics,
            todaySummary: today
        )

        state.loadFailed(
            errorDescription: "  Usage files are temporarily unavailable.  ",
            retryDescription: "  Retry sync  "
        )

        XCTAssertEqual(state.phase, .stale)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.todaySummary, today)
        XCTAssertEqual(state.lastSuccessfulSync, refresh.completedAt)
        XCTAssertEqual(state.errorDescription, "Usage files are temporarily unavailable.")
        XCTAssertEqual(state.retryDescription, "Retry sync")
        XCTAssertTrue(state.hasUsage)
        XCTAssertTrue(state.canRetry)
        XCTAssertFalse(state.isBusy)
    }

    func testFailedInitialLoadBecomesErrorAndRetryCopyIsIndependentlyOptional() {
        var state = DashboardUIState()

        state.loadFailed(
            errorDescription: "Usage could not be read.",
            retryDescription: nil
        )

        XCTAssertEqual(state.phase, .error)
        XCTAssertNil(state.periodMetrics)
        XCTAssertEqual(state.errorDescription, "Usage could not be read.")
        XCTAssertNil(state.retryDescription)
        XCTAssertFalse(state.canRetry)

        state.loadFailed(retryDescription: "Try Again")

        XCTAssertEqual(state.phase, .error)
        XCTAssertNil(state.errorDescription)
        XCTAssertEqual(state.retryDescription, "Try Again")
        XCTAssertTrue(state.canRetry)
    }

    func testBlankTransientDescriptionsAreNormalizedAway() {
        var state = DashboardUIState()
        state.useCached(periodMetrics: makeMetrics(tokens: 1))

        state.loadFailed(
            errorDescription: " \n\t ",
            retryDescription: "  \n "
        )

        XCTAssertEqual(state.phase, .stale)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
        XCTAssertFalse(state.canRetry)
    }

    func testUseCachedInstallsStaleSnapshotWithoutAssertingSyncMetadata() {
        let metrics = makeMetrics(tokens: 800)
        let today = makeToday(tokens: 300)
        var state = DashboardUIState()
        state.loadFailed(errorDescription: "Previous failure")

        state.useCached(
            periodMetrics: metrics,
            todaySummary: today
        )

        XCTAssertEqual(state.phase, .stale)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.todaySummary, today)
        XCTAssertEqual(state.freshness, .unknown)
        XCTAssertNil(state.lastSuccessfulSync)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
    }

    func testUseCachedPreservesAlreadyKnownFreshness() {
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 8, 0))
        let freshness = SyncFreshnessModel(
            lastChecked: refresh.completedAt,
            lastSuccessful: refresh
        )
        var state = DashboardUIState(freshness: freshness)

        state.useCached(periodMetrics: makeMetrics(tokens: 90))

        XCTAssertEqual(state.phase, .stale)
        XCTAssertEqual(state.freshness, freshness)
        XCTAssertEqual(state.lastSuccessfulSync, refresh.completedAt)
    }

    func testBeginLoadingPreservesExistingSnapshotAsStale() {
        let metrics = makeMetrics(tokens: 90)
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 8, 0))
        var state = DashboardUIState(freshness: SyncFreshnessModel(lastSuccessful: refresh))
        state.useCached(periodMetrics: metrics)
        state.loadFailed(errorDescription: "Failed", retryDescription: "Retry")

        state.beginLoading()

        XCTAssertEqual(state.phase, .stale)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.lastSuccessfulSync, refresh.completedAt)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
    }

    func testBeginLoadingWithoutSnapshotReturnsToLoadingAndClearsFailureCopy() {
        var state = DashboardUIState()
        state.loadFailed(errorDescription: "Failed", retryDescription: "Retry")

        state.beginLoading()

        XCTAssertEqual(state.phase, .loading)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
        XCTAssertTrue(state.isBusy)
    }

    func testRetryFromStaleUpdatesAndRetryFromErrorLoads() {
        let metrics = makeMetrics(tokens: 20)
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 7, 0))
        var state = DashboardUIState(freshness: SyncFreshnessModel(lastSuccessful: refresh))
        state.useCached(periodMetrics: metrics)
        state.loadFailed(errorDescription: "Failed", retryDescription: "Retry")

        state.retry()

        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.periodMetrics, metrics)
        XCTAssertEqual(state.lastSuccessfulSync, refresh.completedAt)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)

        state.reset()
        state.loadFailed(errorDescription: "Failed", retryDescription: "Retry")
        state.retry()

        XCTAssertEqual(state.phase, .loading)
        XCTAssertNil(state.periodMetrics)
        XCTAssertEqual(state.freshness, .unknown)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
    }

    func testResetClearsSnapshotFreshnessAndTransientCopy() {
        let refresh = LastSuccessfulRefresh(completedAt: makeDate(2026, 9, 24, 6, 0))
        var state = DashboardUIState(freshness: SyncFreshnessModel(lastSuccessful: refresh))
        state.loadSucceeded(
            periodMetrics: makeMetrics(tokens: 50),
            todaySummary: makeToday(tokens: 10)
        )
        state.loadFailed(errorDescription: "Failed", retryDescription: "Retry")

        state.reset()

        XCTAssertEqual(state.phase, .loading)
        XCTAssertNil(state.periodMetrics)
        XCTAssertNil(state.todaySummary)
        XCTAssertEqual(state.freshness, .unknown)
        XCTAssertNil(state.lastSuccessfulSync)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.retryDescription)
    }

    func testStateDescriptionMatchesCurrentLoadPhase() {
        var state = DashboardUIState()
        XCTAssertEqual(state.stateDescription, "Loading usage")

        state.useCached(periodMetrics: makeMetrics(tokens: 1))
        XCTAssertEqual(state.stateDescription, "Showing cached usage")

        state.beginUpdating()
        XCTAssertEqual(state.stateDescription, "Updating usage")

        state.loadSucceeded(periodMetrics: makeMetrics(tokens: 0))
        XCTAssertEqual(state.stateDescription, "No usage yet")

        state.loadSucceeded(periodMetrics: makeMetrics(tokens: 1))
        XCTAssertEqual(state.stateDescription, "Usage loaded")
    }

    // MARK: - Formatting

    func testLastSyncDescriptionHandlesMissingRecentAndFutureDates() {
        let now = makeDate(2026, 9, 24, 12, 0)
        let calendar = utcCalendar()
        let cases: [(TimeInterval, String)] = [
            (0, "Synced just now"),
            (-59, "Synced just now"),
            (-60, "Synced 1 minute ago"),
            (-119, "Synced 1 minute ago"),
            (-120, "Synced 2 minutes ago"),
            (-3_599, "Synced 59 minutes ago"),
            (-3_600, "Synced 1 hour ago"),
            (-7_200, "Synced 2 hours ago"),
            (60, "Synced just now")
        ]

        XCTAssertEqual(
            DashboardUIState.formatLastSuccessfulSync(nil, relativeTo: now, calendar: calendar),
            "Not synced yet"
        )
        for (offset, expected) in cases {
            XCTAssertEqual(
                DashboardUIState.formatLastSuccessfulSync(
                    now.addingTimeInterval(offset),
                    relativeTo: now,
                    calendar: calendar
                ),
                expected,
                "offset: \(offset)"
            )
        }
    }

    func testLastSyncDescriptionUsesInjectedCalendarForAbsoluteDate() {
        let now = makeDate(2026, 9, 24, 12, 0)
        let previousDay = makeDate(2026, 9, 23, 12, 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        XCTAssertEqual(
            DashboardUIState.formatLastSuccessfulSync(previousDay, relativeTo: now, calendar: calendar),
            "Synced on Sep 23, 2026"
        )
    }

    func testStateAndFreshnessFormatTheirKnownLastSuccessfulRefresh() {
        let now = makeDate(2026, 9, 24, 12, 0)
        let refresh = LastSuccessfulRefresh(completedAt: now.addingTimeInterval(-3_600))
        let freshness = SyncFreshnessModel(
            lastChecked: now,
            lastSuccessful: refresh
        )
        var state = DashboardUIState(freshness: freshness)
        state.loadSucceeded(periodMetrics: makeMetrics(tokens: 10))

        XCTAssertEqual(
            state.lastSuccessfulSyncDescription(relativeTo: now, calendar: utcCalendar()),
            "Synced 1 hour ago"
        )
        XCTAssertEqual(
            freshness.lastSuccessfulDescription(relativeTo: now, calendar: utcCalendar()),
            "Synced 1 hour ago"
        )
    }

    // MARK: - Fixtures

    private func makeMetrics(tokens: Int) -> PeriodMetrics {
        let tool: String? = tokens > 0 ? "pi" : nil
        return PeriodMetrics(
            totalTokens: tokens,
            totalCostUSD: Double(tokens) / 1_000,
            mostActiveTool: tool ?? "None",
            trendPoints: tokens > 0
                ? [TrendPoint(label: "Now", tokens: tokens, costUSD: Double(tokens) / 1_000)]
                : [],
            toolDistribution: tool.map {
                [(tool: $0, tokens: tokens, costUSD: Double(tokens) / 1_000)]
            } ?? [],
            projectRankings: tool.map { _ in
                [(project: "/tmp/project", totalTokens: tokens, costUSD: Double(tokens) / 1_000)]
            } ?? []
        )
    }

    private func makeToday(tokens: Int) -> TodaySummary {
        TodaySummary(
            totalTokens: tokens,
            totalCostUSD: Double(tokens) / 1_000,
            toolTokens: tokens > 0 ? ["pi": tokens] : [:],
            toolCosts: tokens > 0 ? ["pi": Double(tokens) / 1_000] : [:]
        )
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
