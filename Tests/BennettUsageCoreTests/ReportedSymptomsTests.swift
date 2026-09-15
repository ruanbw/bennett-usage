import XCTest
@testable import BennettUsageCore

/// RED tests for the reported symptoms:
/// 1. project folders unstable (Pi hyphen decode + Omp early-line fallback + rankings merge)
/// 2. currency set to $ still shows RMB (spendString must be single-currency)
/// 3. popover shows unused tools (must expose only active tools)
/// 4. status refresh drops bursts (coalescer must run trailing reload)
/// 5. dashboard agent switcher lists agents that were idle in the selected range
final class ReportedSymptomsTests: XCTestCase {
    // MARK: - Currency: single-currency per preference

    func testSpendStringUSDShowsOnlyUSD() {
        let engine = PricingEngine()
        engine.setPreferredCurrency(.usd)
        engine.setExchangeRate(7.30)
        XCTAssertEqual(engine.spendString(10.0), "$10.00")
    }

    func testSpendStringCNYShowsOnlyCNY() {
        let engine = PricingEngine()
        engine.setPreferredCurrency(.cny)
        engine.setExchangeRate(7.30)
        XCTAssertEqual(engine.spendString(10.0), "¥73.00")
    }

    // MARK: - Projects: hyphenated names must not split

    func testPiAdapterPreservesHyphensInProjectFolder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Real project dir with hyphens exists on disk.
        let realProject = tempDir.appendingPathComponent("trove-rag")
        try FileManager.default.createDirectory(at: realProject, withIntermediateDirectories: true)
        // Encoded session folder exactly as Pi writes it for the real path.
        let encoded = "--" + realProject.path.dropFirst().replacingOccurrences(of: "/", with: "-") + "--"
        let sessionFolder = tempDir.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let fileUrl = sessionFolder.appendingPathComponent("s.jsonl")
        let line = """
        {"type":"message","timestamp":"2026-09-11T02:00:00.000Z","model":"m","usage":{"input":10,"output":5}}\n
        """
        try line.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        // Must NOT become ".../trove/rag".
        XCTAssertFalse(result.records[0].projectFolder?.hasSuffix("trove/rag") ?? false)
        XCTAssertTrue(result.records[0].projectFolder?.hasSuffix("trove-rag") ?? false)
    }

    // MARK: - Projects: Omp early lines before session header use session cwd

    func testOmpAdapterBackfillsSessionCwdForEarlyLines() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("-tmp")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileUrl = sessionsDir.appendingPathComponent("s.jsonl")
        // Usage line BEFORE the session header carries no cwd; header arrives later.
        let usageLine = """
        {"message":{"model":"m","usage":{"input":10,"output":5}},"timestamp":"2026-09-11T02:00:00.000Z","id":"msg1"}\n
        """
        let headerLine = """
        {"type":"session","id":"sess1","cwd":"/Users/ruanbw/tmp"}\n
        """
        try (usageLine + headerLine).write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = OmpAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: sessionsDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].projectFolder, "/Users/ruanbw/tmp")
    }

    // MARK: - Projects: rankings merge trailing-slash duplicates

    func testProjectRankingsMergeTrailingSlashDuplicates() throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        func rec(id: String, folder: String) -> UnifiedTokenRecord {
            UnifiedTokenRecord(
                id: id, sourceId: "pi", timestamp: now, sessionKey: "s",
                projectFolder: folder, model: "m", provider: nil,
                inputTokens: 10, outputTokens: 5,
                cacheReadTokens: 0, cacheWriteTokens: 0, rawCostUSD: 0.01
            )
        }
        try db.insertRecords([rec(id: "a", folder: "/tmp/proj"), rec(id: "b", folder: "/tmp/proj/")])
        let rankings = try db.fetchProjectRankings(limit: 100)
        XCTAssertEqual(rankings.count, 1)
        XCTAssertEqual(rankings[0].totalTokens, 30)
    }

    // MARK: - Popover: only active tools

    @MainActor
    func testPopoverActiveToolsFiltersUnused() {
        let summary = TodaySummary(
            totalTokens: 100, totalCostUSD: 1.0,
            toolTokens: ["omp": 100, "pi": 0, "claude": 50],
            toolCosts: ["omp": 0.8, "pi": 0.0, "claude": 0.2]
        )
        let active = MenuBarPopoverView.activeTools(for: summary)
        XCTAssertEqual(active.map(\.id), ["omp", "claude"])
    }
    // MARK: - Dashboard: agent switcher follows the selected range

    /// Cline used ten days ago must not be offered under "Today". The old
    /// implementation unioned the range distribution with the annual heatmap, so
    /// any agent active anywhere in the year stayed in the switcher.
    @MainActor
    func testDashboardAgentSwitcherDropsAgentsIdleInTheSelectedRange() async throws {
        let db = try DatabaseManager.inMemory()
        let aggregator = MetricsAggregator(database: db)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = Date()
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!

        let claudeToday = UnifiedTokenRecord(
            id: "sym_range_1", sourceId: "claude", timestamp: now, dayKey: UnifiedTokenRecord.dayKey(for: now),
            sessionKey: "s1", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 100, outputTokens: 100, rawCostUSD: 0.01
        )
        let clineEarlier = UnifiedTokenRecord(
            id: "sym_range_2", sourceId: "cline", timestamp: tenDaysAgo, dayKey: UnifiedTokenRecord.dayKey(for: tenDaysAgo),
            sessionKey: "s2", projectFolder: nil, model: "m", provider: nil,
            inputTokens: 200, outputTokens: 200, rawCostUSD: 0.02
        )
        try db.insertRecords([claudeToday, clineEarlier])

        // "Today" offers only the agent used today.
        let todayTools = try await aggregator.fetchActiveTools(range: .today)
        XCTAssertEqual(DashboardContentView.agentFilterOptions(activeAgents: todayTools, selectedAgent: nil), ["claude"])

        // A range that contains Cline's usage still offers it.
        let last30Tools = try await aggregator.fetchActiveTools(range: .last30Days)
        XCTAssertEqual(DashboardContentView.agentFilterOptions(activeAgents: last30Tools, selectedAgent: nil), ["claude", "cline"])

        // The year holding that usage knows Cline — that is exactly the set the
        // switcher used to be built from, which is why it leaked into "Today".
        let clineYear = calendar.component(.year, from: tenDaysAgo)
        let yearTools = try await aggregator.fetchActiveTools(range: .year(clineYear))
        XCTAssertTrue(yearTools.contains("cline"))
    }

    // MARK: - Status refresh: bursts collapse with trailing reload

    func testThrottleRunsImmediatelyThenTrails() {
        var throttle = TrailingThrottle(interval: 60)
        let t0 = Date()
        // First request runs immediately.
        XCTAssertTrue(throttle.shouldRunImmediately(at: t0))
        // A burst inside the window does not run now...
        XCTAssertFalse(throttle.shouldRunImmediately(at: t0.addingTimeInterval(1)))
        // ...but schedules exactly one trailer, collapsing repeats.
        XCTAssertTrue(throttle.shouldScheduleTrailer())
        XCTAssertFalse(throttle.shouldScheduleTrailer())
        // After the trailer fires, a new burst may schedule again.
        throttle.trailerFired(at: t0.addingTimeInterval(60))
        XCTAssertFalse(throttle.shouldRunImmediately(at: t0.addingTimeInterval(61)))
        XCTAssertTrue(throttle.shouldScheduleTrailer())
    }
}
