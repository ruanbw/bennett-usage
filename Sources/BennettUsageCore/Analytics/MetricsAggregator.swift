import Foundation

public enum TimeRangeOption: Hashable, Sendable, CustomStringConvertible {
    case last24Hours
    case today
    case last7Days
    case last30Days
    case pastYear
    case year(Int)

    public var description: String {
        switch self {
        case .last24Hours: return "24 Hours"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .pastYear: return "Past Year"
        case .year(let y): return String(y)
        }
    }
}

public struct TrendPoint: Identifiable, Sendable, Equatable {
    public var id: String { label }
    public let label: String
    public let tokens: Int
    public let costUSD: Double
    /// Per-model token breakdown for this bucket. Invariant when non-empty:
    /// `modelTokens.values.reduce(0, +) == tokens`.
    public let modelTokens: [String: Int]

    public init(label: String, tokens: Int, costUSD: Double, modelTokens: [String: Int] = [:]) {
        self.label = label
        self.tokens = tokens
        self.costUSD = costUSD
        self.modelTokens = modelTokens
    }
}

public struct PeriodMetrics: Sendable, Equatable {
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public var cacheHitRate: Double {
        let cacheable = inputTokens + cacheWriteTokens + cacheReadTokens
        guard cacheable > 0 else { return 0.0 }
        return Double(cacheReadTokens) / Double(cacheable)
    }
    public let mostActiveTool: String
    public let trendPoints: [TrendPoint]
    public let toolDistribution: [(tool: String, tokens: Int, costUSD: Double)]
    public let projectRankings: [(project: String, totalTokens: Int, costUSD: Double)]
    public let modelDistribution: [(model: String, tokens: Int, costUSD: Double)]

    public init(
        totalTokens: Int,
        totalCostUSD: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        mostActiveTool: String,
        trendPoints: [TrendPoint],
        toolDistribution: [(tool: String, tokens: Int, costUSD: Double)],
        projectRankings: [(project: String, totalTokens: Int, costUSD: Double)],
        modelDistribution: [(model: String, tokens: Int, costUSD: Double)] = []
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.mostActiveTool = mostActiveTool
        self.trendPoints = trendPoints
        self.toolDistribution = toolDistribution
        self.projectRankings = projectRankings
        self.modelDistribution = modelDistribution
    }
    public static func == (lhs: PeriodMetrics, rhs: PeriodMetrics) -> Bool {
        lhs.totalTokens == rhs.totalTokens
            && lhs.totalCostUSD == rhs.totalCostUSD
            && lhs.inputTokens == rhs.inputTokens
            && lhs.outputTokens == rhs.outputTokens
            && lhs.cacheReadTokens == rhs.cacheReadTokens
            && lhs.cacheWriteTokens == rhs.cacheWriteTokens
            && lhs.mostActiveTool == rhs.mostActiveTool
            && lhs.trendPoints == rhs.trendPoints
            && lhs.toolDistribution.count == rhs.toolDistribution.count
            && zip(lhs.toolDistribution, rhs.toolDistribution).allSatisfy {
                $0.tool == $1.tool && $0.tokens == $1.tokens && $0.costUSD == $1.costUSD
            }
            && lhs.projectRankings.count == rhs.projectRankings.count
            && zip(lhs.projectRankings, rhs.projectRankings).allSatisfy {
                $0.project == $1.project && $0.totalTokens == $1.totalTokens && $0.costUSD == $1.costUSD
            }
            && lhs.modelDistribution.count == rhs.modelDistribution.count
            && zip(lhs.modelDistribution, rhs.modelDistribution).allSatisfy {
                $0.model == $1.model && $0.tokens == $1.tokens && $0.costUSD == $1.costUSD
            }
    }
}

public struct TodaySummary: Sendable, Equatable {
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let toolTokens: [String: Int]
    public let toolCosts: [String: Double]
    /// Today's cache-hit rate, or nil when nothing was cacheable.
    ///
    /// The popover's ring reads this. `daily_rollups.cache_tokens` is reads plus
    /// writes, so the denominator here is input + cache — the same ratio
    /// `PeriodMetrics.cacheHitRate` reports, computed from the rollups the
    /// summary already fetched. nil, never 0, when there are no cache tokens at
    /// all: “nothing was cacheable” and “cache never hit” are different claims,
    /// and a drawn empty ring reads as the second one.
    public let cacheHitRate: Double?

    public init(
        totalTokens: Int,
        totalCostUSD: Double,
        toolTokens: [String: Int],
        toolCosts: [String: Double],
        cacheHitRate: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.toolTokens = toolTokens
        self.toolCosts = toolCosts
        self.cacheHitRate = cacheHitRate
    }

    public init(
        totalTokens: Int,
        totalCostUSD: Double,
        toolBreakdown: [String: Int],
        toolCosts: [String: Double] = [:],
        cacheHitRate: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.toolTokens = toolBreakdown
        self.toolCosts = toolCosts
        self.cacheHitRate = cacheHitRate
    }
}

public struct AgentHealthInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let defaultPath: String
    public let isInstalled: Bool
    public let recordCount: Int
    public let lastRecordTimestamp: Date?

    public init(
        id: String,
        displayName: String,
        defaultPath: String,
        isInstalled: Bool,
        recordCount: Int,
        lastRecordTimestamp: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultPath = defaultPath
        self.isInstalled = isInstalled
        self.recordCount = recordCount
        self.lastRecordTimestamp = lastRecordTimestamp
    }
}

public struct AllTimeTotals: Sendable, Equatable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalCostUSD: Double
    public var cacheHitRate: Double {
        let cacheable = inputTokens + cacheWriteTokens + cacheReadTokens
        guard cacheable > 0 else { return 0.0 }
        return Double(cacheReadTokens) / Double(cacheable)
    }

    public init(
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalCostUSD: Double
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalCostUSD = totalCostUSD
    }
}

public final class MetricsAggregator: Sendable {
    /// Project rankings are intentionally bounded for every period so the
    /// dashboard never has to render an unbounded directory list.
    public static let projectRankingLimit = 100

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public var databasePath: String {
        database.path
    }

    /// Narrows rollups to one tool without per-row String allocations. Stored
    /// sourceIds are lowercase slugs, so the filter is normalized once and
    /// rows compare allocation-free and case-insensitively.
    private func filteredByTool(_ rollups: [DailyRollup], toolFilter: String?) -> [DailyRollup] {
        guard let tool = toolFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else {
            return rollups
        }
        return rollups.filter { $0.sourceId.compare(tool, options: .caseInsensitive) == .orderedSame }
    }

    public func fetchAllTimeTotals(toolFilter: String? = nil) async throws -> AllTimeTotals {
        try database.fetchAllTimeTotals(sourceId: toolFilter)
    }

    // MARK: - Period Comparison

    /// The immediately-preceding window of the same length as `range`.
    ///
    /// This exists so the dashboard can state a period-over-period change
    /// instead of a bare total. A single number answers "how much" but leaves
    /// the reader guessing whether that is normal for them, and guessing is
    /// what a usage tool exists to remove.
    ///
    /// The windows are the natural period boundaries rather than "N days ago":
    /// `today` compares against yesterday, `last24Hours` against the previous
    /// rolling 24 hours. Comparing "today so far" against a whole previous day
    /// would report a drop every morning regardless of behavior.
    public struct ComparisonPeriod: Sendable, Equatable {
        /// Tokens over the preceding window, or nil when the window precedes
        /// all recorded data and a percentage would be a division by zero
        /// dressed up as a finding.
        public let totalTokens: Int?
        public let totalCostUSD: Double?
        public let cacheHitRate: Double?
        /// How many days the database actually covers inside the comparison
        /// window. A 30-day comparison over a 3-day history is reported as
        /// `partialCoverage`, never as a 97% drop.
        public let coveredDays: Int
        public let expectedDays: Int

        /// True when the comparison window is only partly backed by records.
        public var isPartialCoverage: Bool { coveredDays > 0 && coveredDays < expectedDays }
        /// True when the window contains no recorded day at all.
        public var hasNoData: Bool { coveredDays == 0 }
    }

    public func fetchComparisonPeriod(
        range: TimeRangeOption,
        toolFilter: String? = nil,
        now: Date = Date()
    ) async throws -> ComparisonPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        // "Today so far" is compared against yesterday *up to the same clock
        // time*, from raw records.
        //
        // The day-bounded base was a whole yesterday, which reports a large
        // drop every morning purely because today has not finished — the exact
        // failure this type's own documentation warns about. A same-elapsed
        // window is the same length as the value it is compared against.
        if case .today = range {
            let startOfToday = calendar.startOfDay(for: now)
            guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
                return ComparisonPeriod(totalTokens: nil, totalCostUSD: nil, cacheHitRate: nil, coveredDays: 0, expectedDays: 1)
            }
            let elapsed = now.timeIntervalSince(startOfToday)
            let since = Int64(startOfYesterday.timeIntervalSince1970 * 1000)
            let until = since + Int64(max(0, elapsed) * 1000)
            return try comparisonFromRawRecords(since: since, until: until, toolFilter: toolFilter)
        }

        // A rolling 24-hour window has a rolling 24-hour predecessor, and the
        // value it is compared against is aggregated from raw records. The base
        // is therefore aggregated the same way: the day-bounded rollup table
        // can only express whole calendar days, and two of them are 48 hours
        // — long enough to make every 24-hour delta read as a ~2x drop.
        if case .last24Hours = range {
            let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
            return try comparisonFromRawRecords(
                since: nowMillis - 48 * 3_600_000,
                until: nowMillis - 24 * 3_600_000,
                toolFilter: toolFilter
            )
        }

        // A whole-year or a named-year view has no meaningful "previous
        // period" that shares its own boundary semantics, so the UI states no
        // comparison rather than comparing this year against a partial one.
        guard let window = Self.comparisonWindow(for: range, now: now, calendar: calendar) else {
            return ComparisonPeriod(
                totalTokens: nil,
                totalCostUSD: nil,
                cacheHitRate: nil,
                coveredDays: 0,
                expectedDays: 0
            )
        }

        let rollups = filteredByTool(
            try database.fetchDailyRollups(startDate: window.startKey, endDate: window.endKey),
            toolFilter: toolFilter
        )
        let coveredDays = Set(rollups.filter { $0.totalTokens > 0 }.map(\.dayKey)).count

        // The rollups are the source of truth for coverage; the raw-row totals
        // are used for the figures when they exist, and the rollup sum is the
        // fallback so a window still reads correctly before raw retention
        // prunes anything.
        let totals = (try? database.fetchPeriodTotals(
            startDate: window.startKey,
            endDate: window.endKey,
            sourceId: toolFilter
        )) ?? DatabaseManager.PeriodTotals()

        let totalTokens = totals.totalTokens > 0
            ? totals.totalTokens
            : rollups.reduce(0) { $0 + $1.totalTokens }
        let totalCost = totals.totalTokens > 0
            ? totals.totalCostUSD
            : rollups.reduce(0.0) { $0 + $1.costUSD }

        // A hit rate is only meaningful when something could have hit. A window
        // with no cache reads at all has a 0% rate, which reads as "cache is
        // failing" when the truth is "nothing was cacheable" — so it stays nil
        // and the UI says the ratio was not measured.
        let cacheReadTokens = totals.cacheReadTokens
        let cacheable = totals.inputTokens + totals.cacheWriteTokens + cacheReadTokens
        let cacheHitRate = cacheReadTokens > 0
            ? Double(cacheReadTokens) / Double(cacheable)
            : nil

        return ComparisonPeriod(
            totalTokens: coveredDays > 0 ? totalTokens : nil,
            totalCostUSD: coveredDays > 0 ? totalCost : nil,
            cacheHitRate: cacheHitRate,
            coveredDays: coveredDays,
            expectedDays: window.expectedDays
        )
    }

    // MARK: - Range Coverage

    /// How much of the selected window is actually backed by records.
    ///
    /// The numerator and the denominator are deliberately drawn from the same
    /// window. Pairing "days with data anywhere in the heatmap" with "days the
    /// selected range spans" produced readings like `34 / 1` for the 24-hour
    /// view and `34 / 30` for the 30-day view — a fraction whose two halves
    /// describe different things, which is exactly the kind of number this
    /// dashboard exists to remove.
    public struct RangeCoverage: Sendable, Equatable {
        /// Days inside the window that carry at least one record.
        public let recordedDays: Int
        /// Days the window spans.
        public let expectedDays: Int

        /// Share of the window that is covered, clamped to 0...1.
        public var fraction: Double {
            guard expectedDays > 0 else { return 0 }
            return min(1, Double(recordedDays) / Double(expectedDays))
        }

        /// True when the window is only partly backed by records.
        public var isPartial: Bool { recordedDays > 0 && recordedDays < expectedDays }
    }

    public func fetchRangeCoverage(
        range: TimeRangeOption,
        toolFilter: String? = nil,
        now: Date = Date()
    ) async throws -> RangeCoverage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        guard let window = Self.currentWindow(for: range, now: now, calendar: calendar) else {
            return RangeCoverage(recordedDays: 0, expectedDays: 0)
        }

        // The one-day ranges are read from raw records everywhere else — the
        // value, the comparison, the trend — so their coverage is decided the
        // same way. A day-bounded numerator counts records from the whole
        // calendar day the window merely grazes, which reported “1 / 1 covered”
        // for a 24-hour window whose records had all rolled out of it.
        switch range {
        case .last24Hours:
            let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
            return try rawCoverage(since: nowMillis - 24 * 3_600_000, until: nowMillis, toolFilter: toolFilter)
        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            return try rawCoverage(
                since: Int64(startOfToday.timeIntervalSince1970 * 1000),
                until: Int64(now.timeIntervalSince1970 * 1000),
                toolFilter: toolFilter
            )
        default:
            break
        }

        let rollups = filteredByTool(
            try database.fetchDailyRollups(startDate: window.startKey, endDate: window.endKey),
            toolFilter: toolFilter
        )
        let recorded = Set(rollups.filter { $0.totalTokens > 0 }.map(\.dayKey)).count

        // Rollups are day-bounded while `.last24Hours` is a rolling window, so
        // it can legitimately touch two calendar days. Capping keeps the
        // fraction at or below 100% — the claim is "how much of the window has
        // records", not "how many calendar days the window grazed".
        return RangeCoverage(
            recordedDays: min(recorded, window.expectedDays),
            expectedDays: window.expectedDays
        )
    }

    /// Coverage for a single-day window read from raw records: either the window
    /// holds records or it does not.
    private func rawCoverage(since: Int64, until: Int64, toolFilter: String?) throws -> RangeCoverage {
        let totals = (try? database.fetchPeriodTotals(
            sinceTimestamp: since,
            untilTimestamp: until,
            sourceId: toolFilter
        )) ?? DatabaseManager.PeriodTotals()
        return RangeCoverage(recordedDays: totals.totalTokens > 0 ? 1 : 0, expectedDays: 1)
    }

    /// The day keys the selected range spans, plus how many days that is.
    private static func currentWindow(
        for range: TimeRangeOption,
        now: Date,
        calendar: Calendar
    ) -> (startKey: String, endKey: String, expectedDays: Int)? {
        let startOfToday = calendar.startOfDay(for: now)
        let todayKey = UnifiedTokenRecord.dayKey(for: now)

        func window(daysBack: Int, expectedDays: Int) -> (startKey: String, endKey: String, expectedDays: Int)? {
            guard let start = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) else { return nil }
            return (UnifiedTokenRecord.dayKey(for: start), todayKey, expectedDays)
        }

        switch range {
        case .last24Hours:
            return window(daysBack: 1, expectedDays: 1)
        case .today:
            return (todayKey, todayKey, 1)
        case .last7Days:
            return window(daysBack: 6, expectedDays: 7)
        case .last30Days:
            return window(daysBack: 29, expectedDays: 30)
        case .pastYear:
            guard let start = calendar.date(byAdding: .year, value: -1, to: startOfToday),
                  let span = calendar.dateComponents([.day], from: start, to: startOfToday).day else { return nil }
            return (UnifiedTokenRecord.dayKey(for: start), todayKey, span + 1)
        case .year(let year):
            let startKey = "\(year)-01-01"
            let endKey = "\(year)-12-31"
            let span = calendar.range(of: .day, in: .year, for: calendar.date(from: DateComponents(year: year, month: 6, day: 1)) ?? now)?.count ?? 365
            return (startKey, endKey, span)
        }
    }

    /// The one-day comparison windows (`.today`, `.last24Hours`) are aggregated
    /// from raw records, so both halves of the fraction come from the same kind
    /// of source and the same formula the Dashboard uses for the value itself.
    private func comparisonFromRawRecords(
        since: Int64,
        until: Int64,
        toolFilter: String?
    ) throws -> ComparisonPeriod {
        let totals = (try? database.fetchPeriodTotals(
            sinceTimestamp: since,
            untilTimestamp: until,
            sourceId: toolFilter
        )) ?? DatabaseManager.PeriodTotals()

        let cacheable = totals.inputTokens + totals.cacheWriteTokens + totals.cacheReadTokens
        let hasData = totals.totalTokens > 0

        return ComparisonPeriod(
            totalTokens: hasData ? totals.totalTokens : nil,
            totalCostUSD: hasData ? totals.totalCostUSD : nil,
            // No cache reads means the ratio was never measured, which is a
            // different claim from 0%.
            cacheHitRate: totals.cacheReadTokens > 0
                ? Double(totals.cacheReadTokens) / Double(cacheable)
                : nil,
            // A one-day window is either backed by records or it is not.
            coveredDays: hasData ? 1 : 0,
            expectedDays: 1
        )
    }

    /// The day keys of the window immediately before `range`, or nil when the
    /// range has no day-bounded predecessor.
    ///
    /// The windows are contiguous with the range they compare against: the
    /// current 7-day window is `D-6…D0`, so its predecessor is `D-13…D-7`. It
    /// used to be `D-14…D-8`, which both skipped the day next to the window and
    /// reached one day further back than the range itself, so every 7- and
    /// 30-day delta was stated against a window that did not abut it.
    ///
    /// Day-bounded ranges only. `.today` and `.last24Hours` are computed from
    /// raw records in `fetchComparisonPeriod`, and year views have no comparable
    /// predecessor at all.
    private static func comparisonWindow(
        for range: TimeRangeOption,
        now: Date,
        calendar: Calendar
    ) -> (startKey: String, endKey: String, expectedDays: Int)? {
        let startOfToday = calendar.startOfDay(for: now)

        switch range {
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -13, to: startOfToday),
                  let end = calendar.date(byAdding: .day, value: -7, to: startOfToday) else { return nil }
            return (UnifiedTokenRecord.dayKey(for: start), UnifiedTokenRecord.dayKey(for: end), 7)
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -59, to: startOfToday),
                  let end = calendar.date(byAdding: .day, value: -30, to: startOfToday) else { return nil }
            return (UnifiedTokenRecord.dayKey(for: start), UnifiedTokenRecord.dayKey(for: end), 30)
        case .today, .last24Hours, .pastYear, .year:
            return nil
        }
    }

    public func rebuildDailyRollups() async throws {
        try database.rebuildDailyRollups()
        // Rebuilding changes every derived figure on every surface. Clearing
        // announced that; rebuilding did not, so an open Dashboard kept the
        // pre-rebuild numbers until the user touched something.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .bennettUsageDataDidUpdate,
                object: nil,
                userInfo: ["ingested": 0]
            )
        }
    }

    /// Reclaims the write-ahead log after a destructive maintenance action, so
    /// the storage row reflects what the database actually costs on disk.
    public func compactStorage() async {
        await Task.detached(priority: .utility) { [database] in
            database.checkpointAndTruncate()
        }.value
    }

    public func clearAllRecords() async throws {
        try database.clearAllRecords()
        await MainActor.run {
            NotificationCenter.default.post(
                name: .bennettUsageDataDidUpdate,
                object: nil,
                userInfo: ["ingested": 0]
            )
        }
    }

    public func fetchTotalRecordCount() async throws -> Int {
        try database.fetchTotalRecordCount()
    }

    public func fetchAnnualHeatmap(year: Int, toolFilter: String? = nil) async throws -> [HeatmapDayCell] {
        let rollups = filteredByTool(try database.fetchDailyRollups(forYear: year), toolFilter: toolFilter)
        var rollupsByDay: [String: [DailyRollup]] = [:]
        for r in rollups {
            rollupsByDay[r.dayKey, default: []].append(r)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var dateComponents = DateComponents(year: year, month: 1, day: 1)
        guard let startDate = calendar.date(from: dateComponents) else { return [] }

        dateComponents.year = year + 1
        guard let nextYearDate = calendar.date(from: dateComponents) else { return [] }

        // Hide days that have not arrived yet: cap the grid at tomorrow (today included).
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? nextYearDate
        let endDate = min(nextYearDate, tomorrow)

        var days: [(Date, String, Int, Double, [String: Int])] = []
        var currentDate = startDate
        var maxTokens = 0

        while currentDate < endDate {
            let dayKey = UnifiedTokenRecord.dayKey(for: currentDate)
            let items = rollupsByDay[dayKey] ?? []
            var dayTokens = 0
            var dayCost = 0.0
            var breakdown: [String: Int] = [:]
            for item in items {
                dayTokens += item.totalTokens
                dayCost += item.costUSD
                breakdown[item.sourceId, default: 0] += item.totalTokens
            }

            if dayTokens > maxTokens { maxTokens = dayTokens }
            days.append((currentDate, dayKey, dayTokens, dayCost, breakdown))
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? nextYearDate
        }

        return days.map { date, dayKey, tokens, cost, breakdown in
            let level = calculateIntensity(tokens: tokens, maxTokens: maxTokens)
            return HeatmapDayCell(
                date: date,
                dayKey: dayKey,
                totalTokens: tokens,
                costUSD: cost,
                intensityLevel: level,
                toolBreakdown: breakdown
            )
        }
    }

    private func calculateIntensity(tokens: Int, maxTokens: Int) -> Int {
        guard tokens > 0, maxTokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(maxTokens)
        if ratio < 0.15 { return 1 }
        if ratio < 0.40 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }

    public func fetchTodaySummary(toolFilter: String? = nil) async throws -> TodaySummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let startOfToday = calendar.startOfDay(for: Date())
        let sinceTimestamp = Int64(startOfToday.timeIntervalSince1970 * 1000)

        // Raw records, not the rollup table.
        //
        // The rollups merge cache reads and writes into one `cache_tokens`
        // column, so a hit rate derived from them counts a *write* as a hit and
        // cannot reproduce the ratio the Dashboard states for the same day.
        // `timestamp` is also the only basis that survives a time-zone change,
        // because `day_key` is fixed when a record is written.
        let totals = try database.fetchPeriodTotals(sinceTimestamp: sinceTimestamp, sourceId: toolFilter)
        let toolDist = try database.fetchToolDistribution(sourceId: toolFilter, sinceTimestamp: sinceTimestamp)

        var toolTokens: [String: Int] = [:]
        var toolCosts: [String: Double] = [:]
        for entry in toolDist {
            toolTokens[entry.tool] = entry.tokens
            toolCosts[entry.tool] = entry.costUSD
        }

        // Same definition as `PeriodMetrics.cacheHitRate`: reads over input plus
        // cache traffic. Nothing was cacheable ⇒ nil, never 0.
        let cacheable = totals.inputTokens + totals.cacheWriteTokens + totals.cacheReadTokens
        let cacheHitRate = totals.cacheReadTokens > 0
            ? Double(totals.cacheReadTokens) / Double(cacheable)
            : nil

        return TodaySummary(
            totalTokens: totals.totalTokens,
            totalCostUSD: totals.totalCostUSD,
            toolTokens: toolTokens,
            toolCosts: toolCosts,
            cacheHitRate: cacheHitRate
        )
    }

    public func fetchProjectRankings(limit: Int = 100, toolFilter: String? = nil) async throws -> [(project: String, totalTokens: Int, costUSD: Double)] {
        try database.fetchProjectRankings(limit: limit, sourceId: toolFilter)
    }

    /// Every adapter shipped with the app, in registration order. Used as the
    /// fallback when the shared registry is empty (unit tests) and as the
    /// merge-in set for ids the registry does not already provide.
    static func builtInAdapters() -> [any AgentSourceAdapter] {
        AdapterCatalog.defaults
    }

    public func fetchAgentHealthInfos() async throws -> [AgentHealthInfo] {
        var adapters = AdapterRegistry.shared.allAdapters()
        if adapters.isEmpty {
            adapters = Self.builtInAdapters()
        } else {
            let existingIds = Set(adapters.map { $0.sourceId.lowercased() })
            for def in Self.builtInAdapters() {
                if !existingIds.contains(def.sourceId.lowercased()) {
                    adapters.append(def)
                }
            }
        }

        var healthInfos: [AgentHealthInfo] = []
        for adapter in adapters {
            let expandedPath = (adapter.defaultPath as NSString).expandingTildeInPath
            let detectedUrl = adapter.detectDefaultPath()
            let isInstalled = detectedUrl != nil || FileManager.default.fileExists(atPath: expandedPath)
            let stats = try database.fetchRecordStats(forSourceId: adapter.sourceId)
            healthInfos.append(AgentHealthInfo(
                id: adapter.sourceId,
                displayName: adapter.displayName,
                defaultPath: adapter.defaultPath,
                isInstalled: isInstalled,
                recordCount: stats.count,
                lastRecordTimestamp: stats.lastTimestamp
            ))
        }
        return healthInfos
    }

    public func fetchAnnualSummary(year: Int, toolFilter: String? = nil, now: Date = Date()) async throws -> (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String, activeDays: Int, totalDays: Int) {
        let rollups = filteredByTool(try database.fetchDailyRollups(forYear: year), toolFilter: toolFilter)
        var annualTokens = 0
        var annualCostUSD = 0.0
        var toolTokens: [String: Int] = [:]
        var dayTokens: [String: Int] = [:]
        for r in rollups {
            annualTokens += r.totalTokens
            annualCostUSD += r.costUSD
            toolTokens[r.sourceId, default: 0] += r.totalTokens
            dayTokens[r.dayKey, default: 0] += r.totalTokens
        }
        let mostActiveTool: String
        if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mostActiveTool = tool
        } else {
            mostActiveTool = toolTokens.max(by: { $0.value < $1.value })?.key ?? "None"
        }
        let activeDays = dayTokens.filter { $0.value > 0 }.count

        let totalDays = Self.totalDaysElapsed(inYear: year, now: now)
        return (annualTokens: annualTokens, annualCostUSD: annualCostUSD, mostActiveTool: mostActiveTool, activeDays: activeDays, totalDays: totalDays)
    }

    /// Returns the elapsed calendar days for the requested year, including today
    /// when `year` is the current year. Historical years include the full year,
    /// while future years have no elapsed days yet.
    static func totalDaysElapsed(inYear year: Int, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        var calendar = calendar
        calendar.timeZone = .current

        let yearLength = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            .flatMap { calendar.range(of: .day, in: .year, for: $0)?.count } ?? 365
        let currentYear = calendar.component(.year, from: now)
        if year < currentYear { return yearLength }
        if year > currentYear { return 0 }
        return max(1, calendar.ordinality(of: .day, in: .year, for: now) ?? 1)
    }

    public func fetchToolDistribution(year: Int) async throws -> [(tool: String, tokens: Int, costUSD: Double)] {
        let rollups = try database.fetchDailyRollups(forYear: year)
        var tools: [String: (tokens: Int, costUSD: Double)] = [:]
        for r in rollups {
            let current = tools[r.sourceId] ?? (0, 0.0)
            tools[r.sourceId] = (current.tokens + r.totalTokens, current.costUSD + r.costUSD)
        }
        return tools.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Every tool that recorded at least one token inside `range`, ignoring any
    /// tool filter and sorted by id. The dashboard's agent switcher offers
    /// exactly these, so an agent that was idle in the selected range (e.g.
    /// Cline on a day it was never launched) is not listed as a filter option.
    ///
    /// Mirrors the boundaries used by `fetchPeriodMetrics`: sub-day ranges read
    /// records directly, day-and-longer ranges read the rollup table.
    public func fetchActiveTools(range: TimeRangeOption) async throws -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = Date()

        switch range {
        case .last24Hours:
            let since = now.addingTimeInterval(-24 * 3600)
            let sinceTimestamp = Int64(since.timeIntervalSince1970 * 1000)
            return try activeTools(sinceTimestamp: sinceTimestamp)

        case .today:
            let sinceTimestamp = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
            return try activeTools(sinceTimestamp: sinceTimestamp)

        case .last7Days, .last30Days:
            let daysCount = (range == .last7Days) ? 7 : 30
            guard let startDate = calendar.date(byAdding: .day, value: -(daysCount - 1), to: now) else { return [] }
            return try activeTools(inRollups: database.fetchDailyRollups(
                startDate: UnifiedTokenRecord.dayKey(for: startDate),
                endDate: UnifiedTokenRecord.dayKey(for: now)
            ))

        case .pastYear:
            guard let startDate = calendar.date(byAdding: .year, value: -1, to: now) else { return [] }
            return try activeTools(inRollups: database.fetchDailyRollups(
                startDate: UnifiedTokenRecord.dayKey(for: startDate),
                endDate: UnifiedTokenRecord.dayKey(for: now)
            ))

        case .year(let year):
            return try activeTools(inRollups: database.fetchDailyRollups(forYear: year))
        }
    }

    private func activeTools(sinceTimestamp: Int64) throws -> [String] {
        try database.fetchToolDistribution(sinceTimestamp: sinceTimestamp)
            .filter { $0.tokens > 0 }
            .map(\.tool)
            .sorted()
    }

    /// Zero-token rollups (a tool whose records carried no usage) do not count
    /// as "used": the tool donut hides them too, and a pill for an agent showing
    /// 0 tokens everywhere would only be a dead end.
    private func activeTools(inRollups rollups: [DailyRollup]) -> [String] {
        Set(rollups.lazy.filter { $0.totalTokens > 0 }.map(\.sourceId)).sorted()
    }

    public func fetchAvailableYears() async throws -> [Int] {
        let years = try database.fetchAvailableYears()
        if years.isEmpty {
            return [Calendar(identifier: .gregorian).component(.year, from: Date())]
        }
        return years
    }

    public func fetchHeatmap(range: TimeRangeOption, toolFilter: String? = nil) async throws -> [HeatmapDayCell] {
        switch range {
        case .year(let year):
            return try await fetchAnnualHeatmap(year: year, toolFilter: toolFilter)
        default:
            return try await fetchRollingHeatmap(toolFilter: toolFilter)
        }
    }

    public func fetchRollingHeatmap(toolFilter: String? = nil) async throws -> [HeatmapDayCell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let today = Date()

        guard let startDate = calendar.date(byAdding: .day, value: -364, to: today) else {
            return []
        }

        let startKey = UnifiedTokenRecord.dayKey(for: startDate)
        let endKey = UnifiedTokenRecord.dayKey(for: today)
        let rollups = filteredByTool(try database.fetchDailyRollups(startDate: startKey, endDate: endKey), toolFilter: toolFilter)

        var rollupsByDay: [String: [DailyRollup]] = [:]
        for r in rollups {
            rollupsByDay[r.dayKey, default: []].append(r)
        }

        var days: [(Date, String, Int, Double, [String: Int])] = []
        var currentDate = startDate
        var maxTokens = 0

        while currentDate <= today {
            let dayKey = UnifiedTokenRecord.dayKey(for: currentDate)
            let items = rollupsByDay[dayKey] ?? []
            var dayTokens = 0
            var dayCost = 0.0
            var breakdown: [String: Int] = [:]
            for item in items {
                dayTokens += item.totalTokens
                dayCost += item.costUSD
                breakdown[item.sourceId, default: 0] += item.totalTokens
            }

            if dayTokens > maxTokens { maxTokens = dayTokens }
            days.append((currentDate, dayKey, dayTokens, dayCost, breakdown))
            guard let next = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = next
        }

        return days.map { date, dayKey, tokens, cost, breakdown in
            let level = calculateIntensity(tokens: tokens, maxTokens: maxTokens)
            return HeatmapDayCell(
                date: date,
                dayKey: dayKey,
                totalTokens: tokens,
                costUSD: cost,
                intensityLevel: level,
                toolBreakdown: breakdown
            )
        }
    }

    /// Models with the highest total tokens across the given per-bucket
    /// breakdowns, capped at `limit` (matching `fetchModelDistribution`'s
    /// default). Decides which models keep their own series in trend charts;
    /// everything else merges into "Other".
    private static func topModels(across breakdowns: [[String: Int]], limit: Int = 10) -> Set<String> {
        var totals: [String: Int] = [:]
        for breakdown in breakdowns {
            for (model, tokens) in breakdown {
                totals[model, default: 0] += tokens
            }
        }
        return Set(totals.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
    }

    private static func topModels(across breakdownMap: [String: [String: Int]], limit: Int = 10) -> Set<String> {
        topModels(across: Array(breakdownMap.values), limit: limit)
    }

    /// Applies the top-model cap to one bucket's breakdown: models in `top`
    /// keep their own key, everything else merges into "Other". Zero-token
    /// entries are dropped so all-zero buckets keep an empty dictionary.
    private static func cappedModelTokens(_ breakdown: [String: Int], top: Set<String>) -> [String: Int] {
        var capped: [String: Int] = [:]
        for (model, tokens) in breakdown {
            guard tokens > 0 else { continue }
            capped[top.contains(model) ? model : "Other", default: 0] += tokens
        }
        return capped
    }

    /// Groups `fetchHourlyModelBuckets` rows into per-index model breakdowns
    /// using the same index mapping as the caller's `bucketTokens` accumulation.
    private static func modelBreakdowns(
        from buckets: [(hourIndex: Int, model: String, tokens: Int)],
        bucketCount: Int,
        indexMapping: (Int) -> Int?
    ) -> [[String: Int]] {
        var breakdowns: [[String: Int]] = Array(repeating: [:], count: bucketCount)
        for bucket in buckets {
            guard let index = indexMapping(bucket.hourIndex), index >= 0, index < bucketCount else { continue }
            breakdowns[index][bucket.model, default: 0] += bucket.tokens
        }
        return breakdowns
    }

    public func fetchPeriodMetrics(
        range: TimeRangeOption,
        toolFilter: String? = nil,
        localization: LocalizationManager = .shared
    ) async throws -> PeriodMetrics {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = Date()

        switch range {
        case .last24Hours:
            let sinceTime = now.addingTimeInterval(-24 * 3600)
            let sinceTimestamp = Int64(sinceTime.timeIntervalSince1970 * 1000)

            // Totals, tool distribution, project rankings and hour buckets are
            // aggregated in SQL; no raw rows are materialized in Swift.
            let totals = try database.fetchPeriodTotals(sinceTimestamp: sinceTimestamp, sourceId: toolFilter)
            let toolDist = try database.fetchToolDistribution(sourceId: toolFilter, sinceTimestamp: sinceTimestamp)
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: Self.projectRankingLimit, sourceId: toolFilter, sinceTimestamp: sinceTimestamp)

            let currentHour = calendar.date(bySettingHour: calendar.component(.hour, from: now), minute: 0, second: 0, of: now) ?? now
            let currentHourMillis = Int64(currentHour.timeIntervalSince1970 * 1000)
            let buckets = try database.fetchHourlyBuckets(originTimestamp: currentHourMillis, sinceTimestamp: sinceTimestamp, sourceId: toolFilter)

            var bucketTokens = [Int](repeating: 0, count: 24)
            var bucketCosts = [Double](repeating: 0.0, count: 24)
            // SQL yields (timestamp - currentHour)/3600000, i.e. negative
            // whole-hours-ago (0 = current hour); newest bucket is index 23.
            for bucket in buckets {
                // SQLite integer division truncates toward zero, so a record in
                // the first partial hour of the window reports -24 rather than
                // -23: `23 + -24 = -1`, the bucket was discarded, and the
                // oldest stretch of the window disappeared from the chart while
                // still counting toward the total above it. Clamp it into the
                // oldest rendered bar instead.
                let index = min(23, max(0, 23 + bucket.hourIndex))
                bucketTokens[index] += bucket.totalTokens
                bucketCosts[index] += bucket.totalCostUSD
            }
            let modelBuckets = try database.fetchHourlyModelBuckets(originTimestamp: currentHourMillis, sinceTimestamp: sinceTimestamp, sourceId: toolFilter)
            let bucketModels = Self.modelBreakdowns(from: modelBuckets, bucketCount: 24) { 23 + $0 }
            let topModels = Self.topModels(across: bucketModels)

            var trendPoints: [TrendPoint] = []
            for i in 0..<24 {
                let bucketStart = calendar.date(byAdding: .hour, value: -(23 - i), to: currentHour) ?? currentHour
                // Same "HH:00" rendering as the per-call formatter (and the
                // .today branch) without per-refresh ICU setup or printf.
                let hour = calendar.component(.hour, from: bucketStart)
                let hourStr = hour < 10 ? "0\(hour)" : "\(hour)"
                trendPoints.append(TrendPoint(
                    label: "\(hourStr):00",
                    tokens: bucketTokens[i],
                    costUSD: bucketCosts[i],
                    modelTokens: Self.cappedModelTokens(bucketModels[i], top: topModels)
                ))
            }

            let modelDist = (try? database.fetchModelDistribution(limit: 10, sourceId: toolFilter, sinceTimestamp: sinceTimestamp)) ?? []

            return PeriodMetrics(
                totalTokens: totals.totalTokens,
                totalCostUSD: totals.totalCostUSD,
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheWriteTokens: totals.cacheWriteTokens,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings,
                modelDistribution: modelDist
            )


        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            let sinceTimestamp = Int64(startOfToday.timeIntervalSince1970 * 1000)

            // Totals, tool distribution, project rankings and hour buckets are
            // aggregated in SQL; no raw rows are materialized in Swift.
            let totals = try database.fetchPeriodTotals(sinceTimestamp: sinceTimestamp, sourceId: toolFilter)
            let toolDist = try database.fetchToolDistribution(sourceId: toolFilter, sinceTimestamp: sinceTimestamp)
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: Self.projectRankingLimit, sourceId: toolFilter, sinceTimestamp: sinceTimestamp)

            let buckets = try database.fetchHourlyBuckets(originTimestamp: sinceTimestamp, sinceTimestamp: sinceTimestamp, sourceId: toolFilter)

            let currentHour = calendar.component(.hour, from: now)
            let bucketCount = currentHour + 1
            var bucketTokens = [Int](repeating: 0, count: bucketCount)
            var bucketCosts = [Double](repeating: 0.0, count: bucketCount)
            for bucket in buckets {
                let hour = bucket.hourIndex
                guard hour >= 0, hour <= currentHour else { continue }
                bucketTokens[hour] += bucket.totalTokens
                bucketCosts[hour] += bucket.totalCostUSD
            }

            // Only hours that have actually arrived get a bucket; the current
            // hour is kept (it is already "here"), later hours are omitted.
            let modelBuckets = try database.fetchHourlyModelBuckets(originTimestamp: sinceTimestamp, sinceTimestamp: sinceTimestamp, sourceId: toolFilter)
            let bucketModels = Self.modelBreakdowns(from: modelBuckets, bucketCount: bucketCount) { $0 }
            let topModels = Self.topModels(across: bucketModels)

            var trendPoints: [TrendPoint] = []
            for hour in 0...currentHour {
                let hourStr = hour < 10 ? "0\(hour)" : "\(hour)"
                trendPoints.append(TrendPoint(
                    label: "\(hourStr):00",
                    tokens: bucketTokens[hour],
                    costUSD: bucketCosts[hour],
                    modelTokens: Self.cappedModelTokens(bucketModels[hour], top: topModels)
                ))
            }

            let modelDist = (try? database.fetchModelDistribution(limit: 10, sourceId: toolFilter, sinceTimestamp: sinceTimestamp)) ?? []

            return PeriodMetrics(
                totalTokens: totals.totalTokens,
                totalCostUSD: totals.totalCostUSD,
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheWriteTokens: totals.cacheWriteTokens,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings,
                modelDistribution: modelDist
            )


        case .last7Days, .last30Days:
            let daysCount = (range == .last7Days) ? 7 : 30
            guard let startDate = calendar.date(byAdding: .day, value: -(daysCount - 1), to: now) else {
                return PeriodMetrics(totalTokens: 0, totalCostUSD: 0, mostActiveTool: "None", trendPoints: [], toolDistribution: [], projectRankings: [])
            }

            let startKey = UnifiedTokenRecord.dayKey(for: startDate)
            let endKey = UnifiedTokenRecord.dayKey(for: now)

            let rollups = filteredByTool(try database.fetchDailyRollups(startDate: startKey, endDate: endKey), toolFilter: toolFilter)
            let totals = (try? database.fetchPeriodTotals(startDate: startKey, endDate: endKey, sourceId: toolFilter)) ?? DatabaseManager.PeriodTotals()
            let totalTokens = totals.totalTokens > 0 ? totals.totalTokens : rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = totals.totalTokens > 0 ? totals.totalCostUSD : rollups.reduce(0.0) { $0 + $1.costUSD }
            let inputTokens = totals.totalTokens > 0 ? totals.inputTokens : rollups.reduce(0) { $0 + $1.inputTokens }
            let outputTokens = totals.totalTokens > 0 ? totals.outputTokens : rollups.reduce(0) { $0 + $1.outputTokens }
            let cacheReadTokens = totals.cacheReadTokens
            let cacheWriteTokens = totals.cacheWriteTokens

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            var rollupsByDay: [String: [DailyRollup]] = [:]
            for r in rollups {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + r.costUSD)
                rollupsByDay[r.dayKey, default: []].append(r)
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: Self.projectRankingLimit, sourceId: toolFilter, startDate: startKey, endDate: endKey)
            let modelBuckets = (try? database.fetchDailyModelBuckets(startDate: startKey, endDate: endKey, sourceId: toolFilter)) ?? []
            var modelsByDay: [String: [String: Int]] = [:]
            for bucket in modelBuckets {
                modelsByDay[bucket.dayKey, default: [:]][bucket.model, default: 0] += bucket.tokens
            }
            let topModels = Self.topModels(across: modelsByDay)

            let labelFormatter = DateFormatter()
            labelFormatter.dateFormat = (daysCount == 7) ? "E MM/dd" : "MM/dd"
            labelFormatter.timeZone = TimeZone.current

            var trendPoints: [TrendPoint] = []
            var cur = startDate
            while cur <= now {
                let key = UnifiedTokenRecord.dayKey(for: cur)
                let label = labelFormatter.string(from: cur)
                let dayRollups = rollupsByDay[key] ?? []
                var dTokens = 0
                var dCost = 0.0
                for r in dayRollups {
                    dTokens += r.totalTokens
                    dCost += r.costUSD
                }
                trendPoints.append(TrendPoint(label: label, tokens: dTokens, costUSD: dCost, modelTokens: Self.cappedModelTokens(modelsByDay[key] ?? [:], top: topModels)))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cur) else { break }
                cur = next
            }

            let modelDist = (try? database.fetchModelDistribution(limit: 10, sourceId: toolFilter, startDate: startKey, endDate: endKey)) ?? []

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings,
                modelDistribution: modelDist
            )

        case .pastYear:
            guard let startDate = calendar.date(byAdding: .year, value: -1, to: now) else {
                return PeriodMetrics(totalTokens: 0, totalCostUSD: 0, mostActiveTool: "None", trendPoints: [], toolDistribution: [], projectRankings: [])
            }
            let startKey = UnifiedTokenRecord.dayKey(for: startDate)
            let endKey = UnifiedTokenRecord.dayKey(for: now)

            let rollups = filteredByTool(try database.fetchDailyRollups(startDate: startKey, endDate: endKey), toolFilter: toolFilter)
            let totals = (try? database.fetchPeriodTotals(startDate: startKey, endDate: endKey, sourceId: toolFilter)) ?? DatabaseManager.PeriodTotals()
            let totalTokens = totals.totalTokens > 0 ? totals.totalTokens : rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = totals.totalTokens > 0 ? totals.totalCostUSD : rollups.reduce(0.0) { $0 + $1.costUSD }
            let inputTokens = totals.totalTokens > 0 ? totals.inputTokens : rollups.reduce(0) { $0 + $1.inputTokens }
            let outputTokens = totals.totalTokens > 0 ? totals.outputTokens : rollups.reduce(0) { $0 + $1.outputTokens }
            let cacheReadTokens = totals.cacheReadTokens
            let cacheWriteTokens = totals.cacheWriteTokens

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            // Single pass groups months up front; the 12-bucket loop below
            // becomes O(1) lookups instead of re-scanning rollups per month.
            var monthTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in rollups {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + r.costUSD)
                let month = String(r.dayKey.prefix(7))
                let mt = monthTotals[month] ?? (0, 0.0)
                monthTotals[month] = (mt.tokens + r.totalTokens, mt.costUSD + r.costUSD)
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: Self.projectRankingLimit, sourceId: toolFilter, startDate: startKey, endDate: endKey)
            let modelBuckets = (try? database.fetchDailyModelBuckets(startDate: startKey, endDate: endKey, sourceId: toolFilter)) ?? []
            var modelsByMonth: [String: [String: Int]] = [:]
            for bucket in modelBuckets {
                modelsByMonth[String(bucket.dayKey.prefix(7)), default: [:]][bucket.model, default: 0] += bucket.tokens
            }
            let topModels = Self.topModels(across: modelsByMonth)

            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale(identifier: localization.effectiveLanguage.code)
            monthFormatter.dateFormat = "MMM yy"
            monthFormatter.timeZone = TimeZone.current

            var trendPoints: [TrendPoint] = []
            for i in (0..<12).reversed() {
                guard let monthDate = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
                let comp = calendar.dateComponents([.year, .month], from: monthDate)
                guard let y = comp.year, let m = comp.month else { continue }
                let prefix = String(format: "%04d-%02d", y, m)
                let monthLabel = monthFormatter.string(from: monthDate)

                let mTokens = monthTotals[prefix]?.tokens ?? 0
                let mCost = monthTotals[prefix]?.costUSD ?? 0.0
                trendPoints.append(TrendPoint(label: monthLabel, tokens: mTokens, costUSD: mCost, modelTokens: Self.cappedModelTokens(modelsByMonth[prefix] ?? [:], top: topModels)))
            }

            let modelDist = (try? database.fetchModelDistribution(limit: 10, sourceId: toolFilter, startDate: startKey, endDate: endKey)) ?? []

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings,
                modelDistribution: modelDist
            )

        case .year(let year):
            let rollups = filteredByTool(try database.fetchDailyRollups(forYear: year), toolFilter: toolFilter)
            let totals = (try? database.fetchPeriodTotals(year: year, sourceId: toolFilter)) ?? DatabaseManager.PeriodTotals()
            let totalTokens = totals.totalTokens > 0 ? totals.totalTokens : rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = totals.totalTokens > 0 ? totals.totalCostUSD : rollups.reduce(0.0) { $0 + $1.costUSD }
            let inputTokens = totals.totalTokens > 0 ? totals.inputTokens : rollups.reduce(0) { $0 + $1.inputTokens }
            let outputTokens = totals.totalTokens > 0 ? totals.outputTokens : rollups.reduce(0) { $0 + $1.outputTokens }
            let cacheReadTokens = totals.cacheReadTokens
            let cacheWriteTokens = totals.cacheWriteTokens

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            // Single pass groups months up front; the per-month loop below
            // becomes O(1) lookups instead of re-scanning rollups per month.
            var monthTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in rollups {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + r.costUSD)
                let month = String(r.dayKey.prefix(7))
                let mt = monthTotals[month] ?? (0, 0.0)
                monthTotals[month] = (mt.tokens + r.totalTokens, mt.costUSD + r.costUSD)
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: Self.projectRankingLimit, sourceId: toolFilter, startDate: "\(year)-01-01", endDate: "\(year)-12-31")
            let modelBuckets = (try? database.fetchDailyModelBuckets(startDate: "\(year)-01-01", endDate: "\(year)-12-31", sourceId: toolFilter)) ?? []
            var modelsByMonth: [String: [String: Int]] = [:]
            for bucket in modelBuckets {
                modelsByMonth[String(bucket.dayKey.prefix(7)), default: [:]][bucket.model, default: 0] += bucket.tokens
            }
            let topModels = Self.topModels(across: modelsByMonth)

            // The current year only shows months that have started; past years
            // keep all twelve, future years none.
            let currentYear = calendar.component(.year, from: now)
            let monthCount: Int
            if year < currentYear {
                monthCount = 12
            } else if year == currentYear {
                monthCount = calendar.component(.month, from: now)
            } else {
                monthCount = 0
            }
            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale(identifier: localization.effectiveLanguage.code)
            monthFormatter.dateFormat = "MMM"
            monthFormatter.timeZone = TimeZone.current
            var monthNames: [String] = []
            if monthCount > 0 {
                for m in 1...monthCount {
                    guard let monthDate = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { continue }
                    monthNames.append(monthFormatter.string(from: monthDate))
                }
            }
            var trendPoints: [TrendPoint] = []
            if monthCount > 0 {
                for m in 1...monthCount {
                    let prefix = String(format: "%04d-%02d", year, m)
                    let mTokens = monthTotals[prefix]?.tokens ?? 0
                    let mCost = monthTotals[prefix]?.costUSD ?? 0.0
                    trendPoints.append(TrendPoint(label: monthNames[m - 1], tokens: mTokens, costUSD: mCost, modelTokens: Self.cappedModelTokens(modelsByMonth[prefix] ?? [:], top: topModels)))
                }
            }
            let modelDist = (try? database.fetchModelDistribution(limit: 10, sourceId: toolFilter, startDate: "\(year)-01-01", endDate: "\(year)-12-31")) ?? []

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings,
                modelDistribution: modelDist
            )
        }
    }
}
