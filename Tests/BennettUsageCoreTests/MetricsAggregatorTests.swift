import XCTest
@testable import BennettUsageCore

final class MetricsAggregatorTests: XCTestCase {
    var db: DatabaseManager!
    var aggregator: MetricsAggregator!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
        aggregator = MetricsAggregator(database: db)
    }

    func testHeatmapIntensityScaling() async throws {
        let r1 = UnifiedTokenRecord(id: "1", sourceId: "omp", timestamp: Date(), dayKey: "2026-01-15", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 5000, outputTokens: 5000)
        let r2 = UnifiedTokenRecord(id: "2", sourceId: "omp", timestamp: Date(), dayKey: "2026-02-20", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 500_000, outputTokens: 500_000)
        try db.insertRecords([r1, r2])

        let cells = try await aggregator.fetchAnnualHeatmap(year: 2026)
        // Future days of the current year must be excluded.
        XCTAssertFalse(cells.contains { $0.date > Date() })
        XCTAssertTrue(cells.contains { $0.dayKey == "2026-01-15" })
        
        let jan15 = cells.first(where: { $0.dayKey == "2026-01-15" })
        let feb20 = cells.first(where: { $0.dayKey == "2026-02-20" })
        let emptyDay = cells.first(where: { $0.dayKey == "2026-03-01" })

        XCTAssertEqual(emptyDay?.intensityLevel, 0)
        XCTAssertTrue(jan15!.intensityLevel > 0)
        XCTAssertTrue(feb20!.intensityLevel >= jan15!.intensityLevel)
    }

    func testTodaySummary() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(id: "today1", sourceId: "pi", timestamp: Date(), dayKey: todayKey, sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 100, outputTokens: 200, rawCostUSD: 0.05)
        let r2 = UnifiedTokenRecord(id: "today2", sourceId: "omp", timestamp: Date(), dayKey: todayKey, sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 300, outputTokens: 400, rawCostUSD: 0.10)
        try db.insertRecords([r1, r2])

        let summary = try await aggregator.fetchTodaySummary()
        XCTAssertEqual(summary.totalTokens, 1000)
        XCTAssertEqual(summary.totalCostUSD, 0.15, accuracy: 0.0001)
        XCTAssertEqual(summary.toolTokens["pi"], 300)
        XCTAssertEqual(summary.toolTokens["omp"], 700)
        XCTAssertEqual(summary.toolCosts["pi"] ?? 0.0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.toolCosts["omp"] ?? 0.0, 0.10, accuracy: 0.0001)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testProjectRankings() async throws {
        let r1 = UnifiedTokenRecord(id: "p1", sourceId: "pi", timestamp: Date(), dayKey: "2026-03-01", sessionKey: "s1", projectFolder: "/Users/dev/projectA", model: "m", provider: nil, inputTokens: 1000, outputTokens: 2000, rawCostUSD: 0.10)
        let r2 = UnifiedTokenRecord(id: "p2", sourceId: "pi", timestamp: Date(), dayKey: "2026-03-02", sessionKey: "s2", projectFolder: "/Users/dev/projectA", model: "m", provider: nil, inputTokens: 500, outputTokens: 500, rawCostUSD: 0.05)
        let r3 = UnifiedTokenRecord(id: "p3", sourceId: "omp", timestamp: Date(), dayKey: "2026-03-03", sessionKey: "s3", projectFolder: "/Users/dev/projectB", model: "m", provider: nil, inputTokens: 100, outputTokens: 100, rawCostUSD: 0.02)
        let r4 = UnifiedTokenRecord(id: "p4", sourceId: "omp", timestamp: Date(), dayKey: "2026-03-04", sessionKey: "s4", projectFolder: nil, model: "m", provider: nil, inputTokens: 10000, outputTokens: 10000, rawCostUSD: 1.00)
        try db.insertRecords([r1, r2, r3, r4])

        let rankings = try await aggregator.fetchProjectRankings(limit: 5)
        XCTAssertEqual(rankings.count, 2)
        XCTAssertEqual(rankings[0].project, "/Users/dev/projectA")
        XCTAssertEqual(rankings[0].totalTokens, 4000)
        XCTAssertEqual(rankings[0].costUSD, 0.15, accuracy: 0.0001)

        XCTAssertEqual(rankings[1].project, "/Users/dev/projectB")
        XCTAssertEqual(rankings[1].totalTokens, 200)
        XCTAssertEqual(rankings[1].costUSD, 0.02, accuracy: 0.0001)
    }

    func testProjectRankingsAreBoundedAndSortedAcrossPeriods() async throws {
        let now = Date()
        let dayKey = UnifiedTokenRecord.dayKey(for: now)
        let records = (0..<150).map { index in
            let project = String(format: "/tmp/project-%03d", index)
            return UnifiedTokenRecord(
                id: "ranking-\(index)",
                sourceId: "pi",
                timestamp: now,
                dayKey: dayKey,
                sessionKey: "session-\(index)",
                projectFolder: project,
                model: "m",
                provider: nil,
                inputTokens: 1000,
                outputTokens: 0,
                rawCostUSD: Double(index % 3)
            )
        }
        try db.insertRecords(records)

        for range in [TimeRangeOption.last24Hours, .today, .last30Days] {
            let rankings = try await aggregator.fetchPeriodMetrics(range: range).projectRankings
            XCTAssertLessThanOrEqual(rankings.count, MetricsAggregator.projectRankingLimit)
            XCTAssertEqual(rankings.count, MetricsAggregator.projectRankingLimit)
            XCTAssertEqual(rankings.map { $0.project }.count, Set(rankings.map { $0.project }).count)

            for (higher, lower) in zip(rankings, rankings.dropFirst()) {
                if higher.totalTokens == lower.totalTokens {
                    XCTAssertGreaterThanOrEqual(higher.costUSD, lower.costUSD)
                    if higher.costUSD == lower.costUSD {
                        XCTAssertLessThan(higher.project, lower.project)
                    }
                } else {
                    XCTAssertGreaterThan(higher.totalTokens, lower.totalTokens)
                }
            }
        }
    }

    func testProjectRankingsCanonicalMergeStaysBounded() async throws {
        let now = Date()
        let records = (0..<60).flatMap { index -> [UnifiedTokenRecord] in
            let project = String(format: "/tmp/canonical-%03d", index)
            return [project, project + "/"].enumerated().map { variant, folder in
                UnifiedTokenRecord(
                    id: "canonical-\(index)-\(variant)",
                    sourceId: "pi",
                    timestamp: now,
                    dayKey: UnifiedTokenRecord.dayKey(for: now),
                    sessionKey: "session-\(index)-\(variant)",
                    projectFolder: folder,
                    model: "m",
                    provider: nil,
                    inputTokens: 1000,
                    outputTokens: 0,
                    rawCostUSD: 1.0
                )
            }
        }
        try db.insertRecords(records)

        let rankings = try await aggregator.fetchProjectRankings(limit: MetricsAggregator.projectRankingLimit)
        XCTAssertLessThanOrEqual(rankings.count, MetricsAggregator.projectRankingLimit)
        XCTAssertEqual(rankings.count, 50)
        XCTAssertEqual(rankings.map { $0.project }.count, Set(rankings.map { $0.project }).count)
    }

    func testAnnualSummaryAndToolDistribution() async throws {
        let r1 = UnifiedTokenRecord(id: "a1", sourceId: "pi", timestamp: Date(), dayKey: "2026-04-10", sessionKey: "s1", projectFolder: nil, model: "m", provider: nil, inputTokens: 3000, outputTokens: 2000, rawCostUSD: 0.25)
        let r2 = UnifiedTokenRecord(id: "a2", sourceId: "omp", timestamp: Date(), dayKey: "2026-05-15", sessionKey: "s2", projectFolder: nil, model: "m", provider: nil, inputTokens: 1000, outputTokens: 500, rawCostUSD: 0.05)
        let r3 = UnifiedTokenRecord(id: "a3", sourceId: "claude", timestamp: Date(), dayKey: "2026-06-20", sessionKey: "s3", projectFolder: nil, model: "m", provider: nil, inputTokens: 200, outputTokens: 100, rawCostUSD: 0.01)
        let r4 = UnifiedTokenRecord(id: "a4", sourceId: "zero", timestamp: Date(), dayKey: "2026-07-01", sessionKey: "s4", projectFolder: nil, model: "m", provider: nil, inputTokens: 0, outputTokens: 0, rawCostUSD: 0.0)
        try db.insertRecords([r1, r2, r3, r4])

        let summary = try await aggregator.fetchAnnualSummary(year: 2026, now: date(2027, 1, 1))
        XCTAssertEqual(summary.annualTokens, 6800)
        XCTAssertEqual(summary.annualCostUSD, 0.31, accuracy: 0.0001)
        XCTAssertEqual(summary.mostActiveTool, "pi")
        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.totalDays, 365)

        let filteredSummary = try await aggregator.fetchAnnualSummary(year: 2026, toolFilter: "pi", now: date(2027, 1, 1))
        XCTAssertEqual(filteredSummary.annualTokens, 5000)
        XCTAssertEqual(filteredSummary.annualCostUSD, 0.25, accuracy: 0.0001)
        XCTAssertEqual(filteredSummary.mostActiveTool, "pi")
        XCTAssertEqual(filteredSummary.activeDays, 1)
        let distribution = try await aggregator.fetchToolDistribution(year: 2026)
        XCTAssertEqual(distribution.count, 4)
        XCTAssertEqual(distribution[0].tool, "pi")
        XCTAssertEqual(distribution[0].tokens, 5000)
        XCTAssertEqual(distribution[0].costUSD, 0.25, accuracy: 0.0001)

        XCTAssertEqual(distribution[1].tool, "omp")
        XCTAssertEqual(distribution[1].tokens, 1500)
        XCTAssertEqual(distribution[2].tool, "claude")
        XCTAssertEqual(distribution[2].tokens, 300)
        XCTAssertEqual(distribution[3].tool, "zero")
        XCTAssertEqual(distribution[3].tokens, 0)
    }

    func testAnnualSummaryTotalDaysUsesElapsedCalendarDays() async throws {
        let cases: [(year: Int, now: Date, expected: Int)] = [
            (2026, date(2026, 1, 1), 1),
            (2026, date(2026, 2, 28), 59),
            (2028, date(2028, 2, 29), 60),
            (2026, date(2026, 12, 31), 365),
            (2025, date(2026, 1, 1), 365),
            (2024, date(2026, 1, 1), 366),
            (2027, date(2026, 12, 31), 0)
        ]

        for testCase in cases {
            let summary = try await aggregator.fetchAnnualSummary(year: testCase.year, now: testCase.now)
            XCTAssertEqual(summary.totalDays, testCase.expected, "year: \(testCase.year), now: \(testCase.now)")
        }
    }

    func testFetchPeriodMetricsLast24Hours() async throws {
        let now = Date()
        let halfHourAgo = now.addingTimeInterval(-1800)
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 3600)

        let r1 = UnifiedTokenRecord(
            id: "24h_1", sourceId: "omp", timestamp: halfHourAgo, dayKey: "2026-09-11",
            sessionKey: "s1", projectFolder: "/tmp/proj1", model: "m", provider: nil,
            inputTokens: 500, outputTokens: 500, rawCostUSD: 0.10
        )
        let r2 = UnifiedTokenRecord(
            id: "24h_2", sourceId: "pi", timestamp: twentyFiveHoursAgo, dayKey: "2026-09-10",
            sessionKey: "s2", projectFolder: "/tmp/proj2", model: "m", provider: nil,
            inputTokens: 1000, outputTokens: 1000, rawCostUSD: 0.20
        )
        try db.insertRecords([r1, r2])

        let metrics = try await aggregator.fetchPeriodMetrics(range: .last24Hours)
        XCTAssertEqual(metrics.totalTokens, 1000)
        XCTAssertEqual(metrics.totalCostUSD, 0.10, accuracy: 0.0001)
        XCTAssertEqual(metrics.mostActiveTool, "omp")
        XCTAssertEqual(metrics.trendPoints.count, 24)
    }

    func testFetchPeriodMetricsToday() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "td_1", sourceId: "omp", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: "/tmp/proj1", model: "m", provider: nil,
            inputTokens: 300, outputTokens: 200, rawCostUSD: 0.05
        )
        try db.insertRecords([r1])

        let metrics = try await aggregator.fetchPeriodMetrics(range: .today)
        XCTAssertEqual(metrics.totalTokens, 500)
        XCTAssertEqual(metrics.totalCostUSD, 0.05, accuracy: 0.0001)
        // Future hours of today are omitted; the current hour is kept.
        XCTAssertEqual(metrics.trendPoints.count, Calendar.current.component(.hour, from: Date()) + 1)
    }

    func testFetchRollingHeatmap() async throws {
        let cells = try await aggregator.fetchHeatmap(range: .pastYear)
        XCTAssertGreaterThanOrEqual(cells.count, 365)
    }

    func testFetchPeriodMetricsWithToolFilter() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "tf_1", sourceId: "claude", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: "/Users/dev/claudeProject", model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.10
        )
        let r2 = UnifiedTokenRecord(
            id: "tf_2", sourceId: "pi", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s2", projectFolder: "/Users/dev/piProject", model: "m", provider: nil,
            inputTokens: 500, outputTokens: 500, rawCostUSD: 0.50
        )
        try db.insertRecords([r1, r2])

        let claudeMetrics = try await aggregator.fetchPeriodMetrics(range: .today, toolFilter: "claude")
        XCTAssertEqual(claudeMetrics.totalTokens, 200)
        XCTAssertEqual(claudeMetrics.totalCostUSD, 0.10, accuracy: 0.0001)
        XCTAssertEqual(claudeMetrics.mostActiveTool, "claude")
        XCTAssertEqual(claudeMetrics.toolDistribution.count, 1)
        XCTAssertEqual(claudeMetrics.toolDistribution.first?.tool, "claude")
        XCTAssertEqual(claudeMetrics.projectRankings.count, 1)
        XCTAssertEqual(claudeMetrics.projectRankings.first?.project, "/Users/dev/claudeProject")

        let piMetrics = try await aggregator.fetchPeriodMetrics(range: .last7Days, toolFilter: "pi")
        XCTAssertEqual(piMetrics.totalTokens, 1000)
        XCTAssertEqual(piMetrics.totalCostUSD, 0.50, accuracy: 0.0001)
        XCTAssertEqual(piMetrics.mostActiveTool, "pi")
        XCTAssertEqual(piMetrics.toolDistribution.count, 1)
        XCTAssertEqual(piMetrics.toolDistribution.first?.tool, "pi")
    }

    func testFetchActiveToolsScopesToRange() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!
        let oldDate = Date(timeIntervalSince1970: 1_583_000_000) // 2020-03-02 UTC

        // Used today.
        let claudeToday = UnifiedTokenRecord(
            id: "at_1", sourceId: "claude", timestamp: now, dayKey: UnifiedTokenRecord.dayKey(for: now),
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.01
        )
        // Used inside the 30-day window but not today.
        let clineTenDaysAgo = UnifiedTokenRecord(
            id: "at_2", sourceId: "cline", timestamp: tenDaysAgo, dayKey: UnifiedTokenRecord.dayKey(for: tenDaysAgo),
            sessionKey: "s2", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 200, outputTokens: 200, rawCostUSD: 0.02
        )
        // Only present in an old year.
        let piOld = UnifiedTokenRecord(
            id: "at_3", sourceId: "pi", timestamp: oldDate, dayKey: UnifiedTokenRecord.dayKey(for: oldDate),
            sessionKey: "s3", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 300, outputTokens: 300, rawCostUSD: 0.03
        )
        // A record without usage does not make an agent a filter option.
        let traeToday = UnifiedTokenRecord(
            id: "at_4", sourceId: "trae", timestamp: now, dayKey: UnifiedTokenRecord.dayKey(for: now),
            sessionKey: "s4", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 0, outputTokens: 0, rawCostUSD: 0.0
        )
        try db.insertRecords([claudeToday, clineTenDaysAgo, piOld, traeToday])

        // Today: only the agent used today — 10 days ago and the old year are out.
        let today = try await aggregator.fetchActiveTools(range: .today)
        let last24Hours = try await aggregator.fetchActiveTools(range: .last24Hours)
        let last7Days = try await aggregator.fetchActiveTools(range: .last7Days)
        let last30Days = try await aggregator.fetchActiveTools(range: .last30Days)
        let pastYear = try await aggregator.fetchActiveTools(range: .pastYear)
        let year2020 = try await aggregator.fetchActiveTools(range: .year(2020))

        XCTAssertEqual(today, ["claude"])
        XCTAssertEqual(last24Hours, ["claude"])
        XCTAssertEqual(last7Days, ["claude"])
        // Wider ranges pick up the agent that was idle today.
        XCTAssertEqual(last30Days, ["claude", "cline"])
        XCTAssertEqual(pastYear, ["claude", "cline"])
        XCTAssertEqual(year2020, ["pi"])

        // The active filter never narrows the reported set: the filter bar needs
        // the whole range, not just the selected agent.
        let filtered = try await aggregator.fetchPeriodMetrics(range: .last30Days, toolFilter: "cline")
        XCTAssertEqual(filtered.toolDistribution.map(\.tool), ["cline"])
        XCTAssertEqual(last30Days, ["claude", "cline"])
    }

    func testFetchAgentHealthInfos() async throws {
        let r1 = UnifiedTokenRecord(
            id: "ah_1", sourceId: "claude", timestamp: Date(), dayKey: "2026-09-11",
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.05
        )
        try db.insertRecords([r1])

        let healthInfos = try await aggregator.fetchAgentHealthInfos()
        XCTAssertEqual(healthInfos.count, 14)
        let ids = Set(healthInfos.map { $0.id })
        XCTAssertTrue(ids.contains("pi"))
        XCTAssertTrue(ids.contains("omp"))
        XCTAssertTrue(ids.contains("claude"))
        XCTAssertTrue(ids.contains("codex"))
        XCTAssertTrue(ids.contains("gemini"))
        XCTAssertTrue(ids.contains("antigravity"))
        XCTAssertTrue(ids.contains("opencode"))
        XCTAssertTrue(ids.contains("roo"))
        XCTAssertTrue(ids.contains("cline"))
        XCTAssertTrue(ids.contains("qwen"))
        XCTAssertTrue(ids.contains("copilot"))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("trae"))
        XCTAssertTrue(ids.contains("dsh"))

        let claudeInfo = healthInfos.first(where: { $0.id == "claude" })
        XCTAssertNotNil(claudeInfo)
        XCTAssertEqual(claudeInfo?.recordCount, 1)
        XCTAssertNotNil(claudeInfo?.lastRecordTimestamp)
    }

    func testFetchAgentHealthInfosInstalledDetection() async throws {
        struct MockDetectedAdapter: AgentSourceAdapter, @unchecked Sendable {
            let sourceId = "mock-detected"
            let displayName = "Mock Detected"
            let brandColorHex = "#FF0000"
            let sfSymbolIcon = "wrench"
            let defaultPath = "/tmp/definitely-non-existent-path-\(UUID().uuidString)"
            let detectedUrl: URL?

            func detectDefaultPath() -> URL? {
                detectedUrl
            }

            func fetchIncrementalRecords(
                from directory: URL,
                since cursor: SyncCursor?
            ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
                ([], SyncCursor.timestamp(Date()))
            }
        }

        // When detectDefaultPath() returns a URL, isInstalled is true even if defaultPath does not exist
        let tempDir = FileManager.default.temporaryDirectory
        let adapterWithDetected = MockDetectedAdapter(detectedUrl: tempDir)
        let expandedWith = (adapterWithDetected.defaultPath as NSString).expandingTildeInPath
        let detectedUrlWith = adapterWithDetected.detectDefaultPath()
        let isInstalledWith = detectedUrlWith != nil || FileManager.default.fileExists(atPath: expandedWith)
        XCTAssertTrue(isInstalledWith)

        // When detectDefaultPath() returns nil and defaultPath does not exist, isInstalled is false
        let adapterWithoutDetected = MockDetectedAdapter(detectedUrl: nil)
        let expandedWithout = (adapterWithoutDetected.defaultPath as NSString).expandingTildeInPath
        let detectedUrlWithout = adapterWithoutDetected.detectDefaultPath()
        let isInstalledWithout = detectedUrlWithout != nil || FileManager.default.fileExists(atPath: expandedWithout)
        XCTAssertFalse(isInstalledWithout)
    }

    func testFetchHeatmapWithToolFilter() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "hm_1", sourceId: "claude", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 200, outputTokens: 300, rawCostUSD: 0.05
        )
        let r2 = UnifiedTokenRecord(
            id: "hm_2", sourceId: "omp", timestamp: Date(), dayKey: todayKey,
            sessionKey: "s2", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 1000, outputTokens: 1000, rawCostUSD: 0.20
        )
        try db.insertRecords([r1, r2])

        let allCells = try await aggregator.fetchHeatmap(range: .pastYear)
        let todayAll = allCells.first(where: { $0.dayKey == todayKey })
        XCTAssertEqual(todayAll?.totalTokens, 2500)

        let filteredCells = try await aggregator.fetchHeatmap(range: .pastYear, toolFilter: "claude")
        let todayFiltered = filteredCells.first(where: { $0.dayKey == todayKey })
        XCTAssertEqual(todayFiltered?.totalTokens, 500)
        XCTAssertEqual(todayFiltered?.costUSD ?? 0.0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(todayFiltered?.toolBreakdown["claude"], 500)
        XCTAssertNil(todayFiltered?.toolBreakdown["omp"])
    }

    func testFetchAllTimeTotals() async throws {
        // Initial empty state
        let initialTotals = try await aggregator.fetchAllTimeTotals()
        XCTAssertEqual(initialTotals.totalTokens, 0)
        XCTAssertEqual(initialTotals.inputTokens, 0)
        XCTAssertEqual(initialTotals.outputTokens, 0)
        XCTAssertEqual(initialTotals.cacheReadTokens, 0)
        XCTAssertEqual(initialTotals.cacheWriteTokens, 0)
        XCTAssertEqual(initialTotals.totalCostUSD, 0.0, accuracy: 0.0001)
        XCTAssertEqual(initialTotals.cacheHitRate, 0.0, accuracy: 0.0001)

        // Insert records for two tools: claude and omp
        let r1 = UnifiedTokenRecord(
            id: "att_1",
            sourceId: "claude",
            timestamp: Date(),
            dayKey: "2026-03-01",
            sessionKey: "s1",
            projectFolder: nil,
            model: "claude-3-opus",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 3000,
            cacheWriteTokens: 1000,
            rawCostUSD: 0.15
        )
        let r2 = UnifiedTokenRecord(
            id: "att_2",
            sourceId: "omp",
            timestamp: Date(),
            dayKey: "2026-03-02",
            sessionKey: "s2",
            projectFolder: nil,
            model: "gemini-flash",
            provider: "google",
            inputTokens: 2000,
            outputTokens: 1000,
            cacheReadTokens: 1000,
            cacheWriteTokens: 500,
            rawCostUSD: 0.05
        )
        try db.insertRecords([r1, r2])

        // All-time totals without filter
        // Total tokens: r1 (1000+500+3000+1000 = 5500) + r2 (2000+1000+1000+500 = 4500) = 10000
        // Input tokens: 1000 + 2000 = 3000
        // Output tokens: 500 + 1000 = 1500
        // Cache read: 3000 + 1000 = 4000
        // Cache write: 1000 + 500 = 1500
        // Cost: 0.15 + 0.05 = 0.20
        // Cacheable: input(3000) + cacheWrite(1500) + cacheRead(4000) = 8500
        // Cache hit rate: 4000 / 8500 = 0.470588...
        let allTotals = try await aggregator.fetchAllTimeTotals()
        XCTAssertEqual(allTotals.totalTokens, 10000)
        XCTAssertEqual(allTotals.inputTokens, 3000)
        XCTAssertEqual(allTotals.outputTokens, 1500)
        XCTAssertEqual(allTotals.cacheReadTokens, 4000)
        XCTAssertEqual(allTotals.cacheWriteTokens, 1500)
        XCTAssertEqual(allTotals.totalCostUSD, 0.20, accuracy: 0.0001)
        XCTAssertEqual(allTotals.cacheHitRate, 4000.0 / 8500.0, accuracy: 0.0001)

        // Filter by tool "claude" (case-insensitive)
        let claudeTotals = try await aggregator.fetchAllTimeTotals(toolFilter: "Claude")
        XCTAssertEqual(claudeTotals.totalTokens, 5500)
        XCTAssertEqual(claudeTotals.inputTokens, 1000)
        XCTAssertEqual(claudeTotals.outputTokens, 500)
        XCTAssertEqual(claudeTotals.cacheReadTokens, 3000)
        XCTAssertEqual(claudeTotals.cacheWriteTokens, 1000)
        XCTAssertEqual(claudeTotals.totalCostUSD, 0.15, accuracy: 0.0001)
        // Cacheable: 1000 + 1000 + 3000 = 5000; cache hit rate = 3000 / 5000 = 0.6
        XCTAssertEqual(claudeTotals.cacheHitRate, 0.6, accuracy: 0.0001)

        // Filter by tool "omp"
        let ompTotals = try await aggregator.fetchAllTimeTotals(toolFilter: "omp")
        XCTAssertEqual(ompTotals.totalTokens, 4500)
        XCTAssertEqual(ompTotals.inputTokens, 2000)
        XCTAssertEqual(ompTotals.outputTokens, 1000)
        XCTAssertEqual(ompTotals.cacheReadTokens, 1000)
        XCTAssertEqual(ompTotals.cacheWriteTokens, 500)
        XCTAssertEqual(ompTotals.totalCostUSD, 0.05, accuracy: 0.0001)
        // Cacheable: 2000 + 500 + 1000 = 3500; cache hit rate = 1000 / 3500
        XCTAssertEqual(ompTotals.cacheHitRate, 1000.0 / 3500.0, accuracy: 0.0001)
    }

    func testPeriodMetricsTokenBreakdownTodayAnd24Hours() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "pm_today_1",
            sourceId: "claude",
            timestamp: Date(),
            dayKey: todayKey,
            sessionKey: "s1",
            projectFolder: nil,
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 3000,
            cacheWriteTokens: 1000,
            rawCostUSD: 0.12
        )
        try db.insertRecords([r1])

        let todayMetrics = try await aggregator.fetchPeriodMetrics(range: .today)
        XCTAssertEqual(todayMetrics.totalTokens, 5500)
        XCTAssertEqual(todayMetrics.inputTokens, 1000)
        XCTAssertEqual(todayMetrics.outputTokens, 500)
        XCTAssertEqual(todayMetrics.cacheReadTokens, 3000)
        XCTAssertEqual(todayMetrics.cacheWriteTokens, 1000)
        XCTAssertEqual(todayMetrics.totalCostUSD, 0.12, accuracy: 0.0001)
        // Cacheable: 1000 + 1000 + 3000 = 5000; cache hit rate = 3000 / 5000 = 0.6
        XCTAssertEqual(todayMetrics.cacheHitRate, 0.6, accuracy: 0.0001)

        let last24hMetrics = try await aggregator.fetchPeriodMetrics(range: .last24Hours)
        XCTAssertEqual(last24hMetrics.totalTokens, 5500)
        XCTAssertEqual(last24hMetrics.inputTokens, 1000)
        XCTAssertEqual(last24hMetrics.outputTokens, 500)
        XCTAssertEqual(last24hMetrics.cacheReadTokens, 3000)
        XCTAssertEqual(last24hMetrics.cacheWriteTokens, 1000)
        XCTAssertEqual(last24hMetrics.totalCostUSD, 0.12, accuracy: 0.0001)
        XCTAssertEqual(last24hMetrics.cacheHitRate, 0.6, accuracy: 0.0001)
    }

    func testPeriodMetricsTokenBreakdownLast7DaysAndYear() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let r1 = UnifiedTokenRecord(
            id: "pm_range_1",
            sourceId: "omp",
            timestamp: Date(),
            dayKey: todayKey,
            sessionKey: "s1",
            projectFolder: nil,
            model: "gemini-flash",
            provider: "google",
            inputTokens: 2000,
            outputTokens: 800,
            cacheReadTokens: 1200,
            cacheWriteTokens: 400,
            rawCostUSD: 0.08
        )
        try db.insertRecords([r1])

        let metrics7d = try await aggregator.fetchPeriodMetrics(range: .last7Days)
        XCTAssertEqual(metrics7d.totalTokens, 4400)
        XCTAssertEqual(metrics7d.inputTokens, 2000)
        XCTAssertEqual(metrics7d.outputTokens, 800)
        XCTAssertEqual(metrics7d.cacheReadTokens, 1200)
        XCTAssertEqual(metrics7d.cacheWriteTokens, 400)
        XCTAssertEqual(metrics7d.totalCostUSD, 0.08, accuracy: 0.0001)
        // Cacheable: 2000 + 400 + 1200 = 3600; hit rate = 1200 / 3600 = 1/3
        XCTAssertEqual(metrics7d.cacheHitRate, 1200.0 / 3600.0, accuracy: 0.0001)

        let year = Calendar.current.component(.year, from: Date())
        let metricsYear = try await aggregator.fetchPeriodMetrics(range: .year(year))
        XCTAssertEqual(metricsYear.totalTokens, 4400)
        XCTAssertEqual(metricsYear.inputTokens, 2000)
        XCTAssertEqual(metricsYear.outputTokens, 800)
        XCTAssertEqual(metricsYear.cacheReadTokens, 1200)
        XCTAssertEqual(metricsYear.cacheWriteTokens, 400)
        XCTAssertEqual(metricsYear.totalCostUSD, 0.08, accuracy: 0.0001)
        XCTAssertEqual(metricsYear.cacheHitRate, 1200.0 / 3600.0, accuracy: 0.0001)
    }

    func testDatabaseManagerFetchPeriodTotals() throws {
        let r1 = UnifiedTokenRecord(
            id: "pt_1",
            sourceId: "claude",
            timestamp: Date(),
            dayKey: "2026-05-10",
            sessionKey: "s1",
            projectFolder: nil,
            model: "m",
            provider: nil,
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 300,
            cacheWriteTokens: 400,
            rawCostUSD: 0.05
        )
        let r2 = UnifiedTokenRecord(
            id: "pt_2",
            sourceId: "pi",
            timestamp: Date(),
            dayKey: "2026-05-15",
            sessionKey: "s2",
            projectFolder: nil,
            model: "m",
            provider: nil,
            inputTokens: 50,
            outputTokens: 50,
            cacheReadTokens: 100,
            cacheWriteTokens: 0,
            rawCostUSD: 0.02
        )
        try db.insertRecords([r1, r2])

        // Range covering both
        let totalsAll = try db.fetchPeriodTotals(startDate: "2026-05-01", endDate: "2026-05-31")
        XCTAssertEqual(totalsAll.totalTokens, 1200)
        XCTAssertEqual(totalsAll.inputTokens, 150)
        XCTAssertEqual(totalsAll.outputTokens, 250)
        XCTAssertEqual(totalsAll.cacheReadTokens, 400)
        XCTAssertEqual(totalsAll.cacheWriteTokens, 400)
        XCTAssertEqual(totalsAll.totalCostUSD, 0.07, accuracy: 0.0001)

        // Filter by sourceId
        let totalsClaude = try db.fetchPeriodTotals(startDate: "2026-05-01", endDate: "2026-05-31", sourceId: "claude")
        XCTAssertEqual(totalsClaude.totalTokens, 1000)
        XCTAssertEqual(totalsClaude.inputTokens, 100)
        XCTAssertEqual(totalsClaude.outputTokens, 200)
        XCTAssertEqual(totalsClaude.cacheReadTokens, 300)
        XCTAssertEqual(totalsClaude.cacheWriteTokens, 400)
        XCTAssertEqual(totalsClaude.totalCostUSD, 0.05, accuracy: 0.0001)

        // Filter by year
        let totalsYear = try db.fetchPeriodTotals(year: 2026)
        XCTAssertEqual(totalsYear.totalTokens, 1200)

        // Year with no records
        let totalsEmpty = try db.fetchPeriodTotals(year: 2024)
        XCTAssertEqual(totalsEmpty.totalTokens, 0)
    }

    // MARK: - Per-model trend buckets

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)!
    }

    func testFetchHourlyModelBuckets() throws {
        let origin = date("2026-03-01 08:00")
        let originMillis = Int64(origin.timeIntervalSince1970 * 1000)
        func atHour(_ hours: Int) -> Date {
            origin.addingTimeInterval(TimeInterval(hours) * 3600)
        }

        let records = [
            UnifiedTokenRecord(id: "hm1", sourceId: "pi", timestamp: atHour(0), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 100, outputTokens: 0),
            UnifiedTokenRecord(id: "hm2", sourceId: "pi", timestamp: atHour(0), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 50, outputTokens: 0),
            UnifiedTokenRecord(id: "hm3", sourceId: "omp", timestamp: atHour(2), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 70, outputTokens: 0),
            UnifiedTokenRecord(id: "hm4", sourceId: "pi", timestamp: atHour(2), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 30, outputTokens: 0),
        ]
        try db.insertRecords(records)

        let buckets = try db.fetchHourlyModelBuckets(originTimestamp: originMillis, sinceTimestamp: originMillis)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertTrue(buckets.contains { $0.hourIndex == 0 && $0.model == "claude-opus" && $0.tokens == 100 })
        XCTAssertTrue(buckets.contains { $0.hourIndex == 0 && $0.model == "glm-5" && $0.tokens == 50 })
        XCTAssertTrue(buckets.contains { $0.hourIndex == 2 && $0.model == "claude-opus" && $0.tokens == 70 })
        XCTAssertTrue(buckets.contains { $0.hourIndex == 2 && $0.model == "glm-5" && $0.tokens == 30 })

        let piBuckets = try db.fetchHourlyModelBuckets(originTimestamp: originMillis, sinceTimestamp: originMillis, sourceId: "pi")
        XCTAssertEqual(piBuckets.count, 3)
        XCTAssertFalse(piBuckets.contains { $0.model == "claude-opus" && $0.tokens == 70 })

        // Invariant: per-hour model sums equal the un-split hourly bucket totals.
        let totals = try db.fetchHourlyBuckets(originTimestamp: originMillis, sinceTimestamp: originMillis)
        for total in totals {
            let modelSum = buckets.filter { $0.hourIndex == total.hourIndex }.reduce(0) { $0 + $1.tokens }
            XCTAssertEqual(modelSum, total.totalTokens)
        }
    }

    func testFetchDailyModelBuckets() throws {
        let records = [
            UnifiedTokenRecord(id: "dm1", sourceId: "pi", timestamp: date("2026-03-01 12:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 100, outputTokens: 0),
            UnifiedTokenRecord(id: "dm2", sourceId: "pi", timestamp: date("2026-03-01 18:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 40, outputTokens: 0),
            UnifiedTokenRecord(id: "dm3", sourceId: "omp", timestamp: date("2026-03-03 09:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 60, outputTokens: 0),
        ]
        try db.insertRecords(records)

        let buckets = try db.fetchDailyModelBuckets(startDate: "2026-03-01", endDate: "2026-03-31")
        XCTAssertEqual(buckets.count, 3)
        XCTAssertTrue(buckets.contains { $0.dayKey == "2026-03-01" && $0.model == "claude-opus" && $0.tokens == 100 })
        XCTAssertTrue(buckets.contains { $0.dayKey == "2026-03-01" && $0.model == "glm-5" && $0.tokens == 40 })
        XCTAssertTrue(buckets.contains { $0.dayKey == "2026-03-03" && $0.model == "glm-5" && $0.tokens == 60 })

        let filtered = try db.fetchDailyModelBuckets(startDate: "2026-03-01", endDate: "2026-03-31", sourceId: "omp")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.dayKey, "2026-03-03")
        XCTAssertEqual(filtered.first?.model, "glm-5")
        XCTAssertEqual(filtered.first?.tokens, 60)

        // Range boundaries are inclusive; a day without records yields nothing.
        let clipped = try db.fetchDailyModelBuckets(startDate: "2026-03-02", endDate: "2026-03-02")
        XCTAssertTrue(clipped.isEmpty)
    }

    func testPeriodMetricsModelTokensHourlyRanges() async throws {
        let now = Date()
        let records = [
            UnifiedTokenRecord(id: "mt1", sourceId: "pi", timestamp: now, dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 120, outputTokens: 0),
            UnifiedTokenRecord(id: "mt2", sourceId: "pi", timestamp: now, dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 80, outputTokens: 0),
        ]
        try db.insertRecords(records)

        let metrics24 = try await aggregator.fetchPeriodMetrics(range: .last24Hours)
        XCTAssertEqual(metrics24.trendPoints.count, 24)
        let newest = metrics24.trendPoints[23]
        XCTAssertEqual(newest.tokens, 200)
        XCTAssertEqual(newest.modelTokens["claude-opus"], 120)
        XCTAssertEqual(newest.modelTokens["glm-5"], 80)
        XCTAssertEqual(newest.modelTokens.values.reduce(0, +), newest.tokens)

        let today = try await aggregator.fetchPeriodMetrics(range: .today)
        // Future hours of today must not appear; the current hour is kept.
        let currentHour = Calendar.current.component(.hour, from: now)
        XCTAssertEqual(today.trendPoints.count, currentHour + 1)
        let hourPoint = today.trendPoints[currentHour]
        XCTAssertEqual(hourPoint.tokens, 200)
        XCTAssertEqual(hourPoint.modelTokens["claude-opus"], 120)
        XCTAssertEqual(hourPoint.modelTokens["glm-5"], 80)
        XCTAssertEqual(hourPoint.modelTokens.values.reduce(0, +), hourPoint.tokens)
    }

    func testPeriodMetricsModelTokensDailyRange() async throws {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        let weekAgo = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        let weekAgoKey = dayFormatter.string(from: weekAgo)

        let records = [
            UnifiedTokenRecord(id: "w1", sourceId: "pi", timestamp: date("\(weekAgoKey) 12:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 300, outputTokens: 0),
            UnifiedTokenRecord(id: "w2", sourceId: "pi", timestamp: date("\(weekAgoKey) 18:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 100, outputTokens: 0),
            UnifiedTokenRecord(id: "w3", sourceId: "pi", timestamp: Date(), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 50, outputTokens: 0),
        ]
        try db.insertRecords(records)

        let metrics = try await aggregator.fetchPeriodMetrics(range: .last7Days)
        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "E MM/dd"
        labelFormatter.timeZone = TimeZone.current
        let weekAgoLabel = labelFormatter.string(from: weekAgo)

        let point = metrics.trendPoints.first { $0.label == weekAgoLabel }
        XCTAssertNotNil(point)
        XCTAssertEqual(point?.tokens, 400)
        XCTAssertEqual(point?.modelTokens["claude-opus"], 300)
        XCTAssertEqual(point?.modelTokens["glm-5"], 100)
        XCTAssertEqual(point?.modelTokens.values.reduce(0, +), point?.tokens)

        // Today's point carries only the record written now.
        let todayPoint = metrics.trendPoints.last
        XCTAssertEqual(todayPoint?.tokens, 50)
        XCTAssertEqual(todayPoint?.modelTokens, ["claude-opus": 50])
    }

    func testPeriodMetricsModelTokensTop10Capping() async throws {
        let now = Date()
        var records: [UnifiedTokenRecord] = []
        for i in 0..<12 {
            records.append(UnifiedTokenRecord(
                id: "cap\(i)", sourceId: "pi", timestamp: now, dayKey: nil, sessionKey: "s",
                projectFolder: nil, model: "model-\(i)", provider: nil,
                inputTokens: (i + 1) * 10, outputTokens: 0
            ))
        }
        try db.insertRecords(records)

        let metrics = try await aggregator.fetchPeriodMetrics(range: .last24Hours)
        let newest = metrics.trendPoints[23]
        XCTAssertEqual(newest.tokens, 780)
        XCTAssertEqual(newest.modelTokens.count, 11) // top 10 models + "Other"
        XCTAssertEqual(newest.modelTokens["model-11"], 120)
        XCTAssertEqual(newest.modelTokens["Other"], 30) // model-0 (10) + model-1 (20)
        XCTAssertNil(newest.modelTokens["model-0"])
        XCTAssertNil(newest.modelTokens["model-1"])
        XCTAssertEqual(newest.modelTokens.values.reduce(0, +), 780)
    }

    func testPeriodMetricsModelTokensMonthlyYear() async throws {
        let records = [
            UnifiedTokenRecord(id: "y1", sourceId: "pi", timestamp: date("2026-03-05 12:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 500, outputTokens: 0),
            UnifiedTokenRecord(id: "y2", sourceId: "pi", timestamp: date("2026-03-20 12:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "glm-5", provider: nil, inputTokens: 250, outputTokens: 0),
            UnifiedTokenRecord(id: "y3", sourceId: "pi", timestamp: date("2026-04-10 12:00"), dayKey: nil, sessionKey: "s", projectFolder: nil, model: "claude-opus", provider: nil, inputTokens: 100, outputTokens: 0),
        ]
        try db.insertRecords(records)

        let metrics = try await aggregator.fetchPeriodMetrics(range: .year(2026))
        XCTAssertEqual(metrics.trendPoints[2].tokens, 750) // Mar
        XCTAssertEqual(metrics.trendPoints[2].modelTokens["claude-opus"], 500)
        XCTAssertEqual(metrics.trendPoints[2].modelTokens["glm-5"], 250)
        XCTAssertEqual(metrics.trendPoints[3].tokens, 100) // Apr
        XCTAssertEqual(metrics.trendPoints[3].modelTokens, ["claude-opus": 100])
        XCTAssertEqual(metrics.trendPoints[0].modelTokens, [:]) // empty month

        // The current year only shows months that have started.
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentMetrics = try await aggregator.fetchPeriodMetrics(range: .year(currentYear))
        XCTAssertEqual(currentMetrics.trendPoints.count, calendar.component(.month, from: Date()))
    }
}
