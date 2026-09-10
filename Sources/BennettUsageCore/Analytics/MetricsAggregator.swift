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

    public init(label: String, tokens: Int, costUSD: Double) {
        self.label = label
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct PeriodMetrics: Sendable {
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let mostActiveTool: String
    public let trendPoints: [TrendPoint]
    public let toolDistribution: [(tool: String, tokens: Int, costUSD: Double)]
    public let projectRankings: [(project: String, totalTokens: Int, costUSD: Double)]

    public init(
        totalTokens: Int,
        totalCostUSD: Double,
        mostActiveTool: String,
        trendPoints: [TrendPoint],
        toolDistribution: [(tool: String, tokens: Int, costUSD: Double)],
        projectRankings: [(project: String, totalTokens: Int, costUSD: Double)]
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.mostActiveTool = mostActiveTool
        self.trendPoints = trendPoints
        self.toolDistribution = toolDistribution
        self.projectRankings = projectRankings
    }
}

public struct TodaySummary: Sendable, Equatable {
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let toolTokens: [String: Int]
    public let toolCosts: [String: Double]

    public init(
        totalTokens: Int,
        totalCostUSD: Double,
        toolTokens: [String: Int],
        toolCosts: [String: Double]
    ) {
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.toolTokens = toolTokens
        self.toolCosts = toolCosts
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

public final class MetricsAggregator: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAnnualHeatmap(year: Int, toolFilter: String? = nil) async throws -> [HeatmapDayCell] {
        var rollups = try database.fetchDailyRollups(forYear: year)
        if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            rollups = rollups.filter { $0.sourceId.lowercased() == filterLower }
        }
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

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        var days: [(Date, String, Int, Double, [String: Int])] = []
        var currentDate = startDate
        var maxTokens = 0

        while currentDate < nextYearDate {
            let dayKey = dayFormatter.string(from: currentDate)
            let items = rollupsByDay[dayKey] ?? []
            let dayTokens = items.reduce(0) { $0 + $1.totalTokens }
            let dayCost = items.reduce(0.0) { $0 + $1.costUSD }
            var breakdown: [String: Int] = [:]
            for item in items {
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

    public func fetchTodaySummary() async throws -> TodaySummary {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let rollups = try database.fetchDailyRollups(forYear: year).filter { $0.dayKey == todayKey }

        let totalTokens = rollups.reduce(0) { $0 + $1.totalTokens }
        let totalCost = rollups.reduce(0.0) { $0 + $1.costUSD }
        var toolTokens: [String: Int] = [:]
        var toolCosts: [String: Double] = [:]

        for r in rollups {
            toolTokens[r.sourceId, default: 0] += r.totalTokens
            toolCosts[r.sourceId, default: 0.0] += r.costUSD
        }

        return TodaySummary(
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            toolTokens: toolTokens,
            toolCosts: toolCosts
        )
    }

    public func fetchProjectRankings(limit: Int = 10, toolFilter: String? = nil) async throws -> [(project: String, totalTokens: Int, costUSD: Double)] {
        try database.fetchProjectRankings(limit: limit, sourceId: toolFilter)
    }

    public func fetchAgentHealthInfos() async throws -> [AgentHealthInfo] {
        var adapters = AdapterRegistry.shared.allAdapters()
        if adapters.isEmpty {
            adapters = [PiAdapter(), OmpAdapter(), ClaudeAdapter(), CodexAdapter()]
        } else {
            let existingIds = Set(adapters.map { $0.sourceId.lowercased() })
            let defaults: [AgentSourceAdapter] = [PiAdapter(), OmpAdapter(), ClaudeAdapter(), CodexAdapter()]
            for def in defaults {
                if !existingIds.contains(def.sourceId.lowercased()) {
                    adapters.append(def)
                }
            }
        }

        var healthInfos: [AgentHealthInfo] = []
        for adapter in adapters {
            let expandedPath = (adapter.defaultPath as NSString).expandingTildeInPath
            let isInstalled = FileManager.default.fileExists(atPath: expandedPath)
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

    public func fetchAnnualSummary(year: Int) async throws -> (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String) {
        let rollups = try database.fetchDailyRollups(forYear: year)
        let annualTokens = rollups.reduce(0) { $0 + $1.totalTokens }
        let annualCostUSD = rollups.reduce(0.0) { $0 + $1.costUSD }
        var toolTokens: [String: Int] = [:]
        for r in rollups {
            toolTokens[r.sourceId, default: 0] += r.totalTokens
        }
        let mostActiveTool = toolTokens.max(by: { $0.value < $1.value })?.key ?? "None"
        return (annualTokens: annualTokens, annualCostUSD: annualCostUSD, mostActiveTool: mostActiveTool)
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

    public func fetchAvailableYears() async throws -> [Int] {
        let years = try database.fetchAvailableYears()
        if years.isEmpty {
            return [Calendar.current.component(.year, from: Date())]
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

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        let startKey = dayFormatter.string(from: startDate)
        let endKey = dayFormatter.string(from: today)
        var rollups = try database.fetchDailyRollups(startDate: startKey, endDate: endKey)
        if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            rollups = rollups.filter { $0.sourceId.lowercased() == filterLower }
        }

        var rollupsByDay: [String: [DailyRollup]] = [:]
        for r in rollups {
            rollupsByDay[r.dayKey, default: []].append(r)
        }

        var days: [(Date, String, Int, Double, [String: Int])] = []
        var currentDate = startDate
        var maxTokens = 0

        while currentDate <= today {
            let dayKey = dayFormatter.string(from: currentDate)
            let items = rollupsByDay[dayKey] ?? []
            let dayTokens = items.reduce(0) { $0 + $1.totalTokens }
            let dayCost = items.reduce(0.0) { $0 + $1.costUSD }
            var breakdown: [String: Int] = [:]
            for item in items {
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

    public func fetchPeriodMetrics(range: TimeRangeOption, toolFilter: String? = nil) async throws -> PeriodMetrics {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = Date()

        switch range {
        case .last24Hours:
            let sinceTime = now.addingTimeInterval(-24 * 3600)
            let sinceTimestamp = Int64(sinceTime.timeIntervalSince1970 * 1000)
            var records = try database.fetchRecords(sinceTimestamp: sinceTimestamp)
            if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                records = records.filter { $0.sourceId.lowercased() == filterLower }
            }

            let totalTokens = records.reduce(0) { $0 + $1.totalTokens }
            let totalCost = records.reduce(0.0) { $0 + ($1.rawCostUSD ?? 0.0) }

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in records {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + (r.rawCostUSD ?? 0.0))
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"

            var projTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in records {
                if let p = r.projectFolder, !p.isEmpty {
                    let cur = projTotals[p] ?? (0, 0.0)
                    projTotals[p] = (cur.tokens + r.totalTokens, cur.costUSD + (r.rawCostUSD ?? 0.0))
                }
            }
            let projRankings = projTotals.map { (project: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.totalTokens > $1.totalTokens }

            let hourFormatter = DateFormatter()
            hourFormatter.dateFormat = "HH:00"
            hourFormatter.timeZone = TimeZone.current

            var trendPoints: [TrendPoint] = []
            for i in 0..<24 {
                let bucketStart = now.addingTimeInterval(-Double(23 - i) * 3600)
                let bucketEnd = bucketStart.addingTimeInterval(3600)
                let label = hourFormatter.string(from: bucketStart)

                let bucketRecords = records.filter {
                    $0.timestamp >= bucketStart && $0.timestamp < bucketEnd
                }
                let bTokens = bucketRecords.reduce(0) { $0 + $1.totalTokens }
                let bCost = bucketRecords.reduce(0.0) { $0 + ($1.rawCostUSD ?? 0.0) }
                trendPoints.append(TrendPoint(label: label, tokens: bTokens, costUSD: bCost))
            }

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings
            )

        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            let sinceTimestamp = Int64(startOfToday.timeIntervalSince1970 * 1000)
            var records = try database.fetchRecords(sinceTimestamp: sinceTimestamp)
            if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                records = records.filter { $0.sourceId.lowercased() == filterLower }
            }

            let totalTokens = records.reduce(0) { $0 + $1.totalTokens }
            let totalCost = records.reduce(0.0) { $0 + ($1.rawCostUSD ?? 0.0) }

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in records {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + (r.rawCostUSD ?? 0.0))
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"

            var projTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in records {
                if let p = r.projectFolder, !p.isEmpty {
                    let cur = projTotals[p] ?? (0, 0.0)
                    projTotals[p] = (cur.tokens + r.totalTokens, cur.costUSD + (r.rawCostUSD ?? 0.0))
                }
            }
            let projRankings = projTotals.map { (project: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.totalTokens > $1.totalTokens }

            var trendPoints: [TrendPoint] = []
            for hour in 0..<24 {
                let bucketStart = calendar.date(byAdding: .hour, value: hour, to: startOfToday) ?? startOfToday
                let bucketEnd = calendar.date(byAdding: .hour, value: hour + 1, to: startOfToday) ?? startOfToday
                let label = String(format: "%02d:00", hour)

                let bucketRecords = records.filter {
                    $0.timestamp >= bucketStart && $0.timestamp < bucketEnd
                }
                let bTokens = bucketRecords.reduce(0) { $0 + $1.totalTokens }
                let bCost = bucketRecords.reduce(0.0) { $0 + ($1.rawCostUSD ?? 0.0) }
                trendPoints.append(TrendPoint(label: label, tokens: bTokens, costUSD: bCost))
            }

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings
            )

        case .last7Days, .last30Days:
            let daysCount = (range == .last7Days) ? 7 : 30
            guard let startDate = calendar.date(byAdding: .day, value: -(daysCount - 1), to: now) else {
                return PeriodMetrics(totalTokens: 0, totalCostUSD: 0, mostActiveTool: "None", trendPoints: [], toolDistribution: [], projectRankings: [])
            }

            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone.current
            let startKey = dayFormatter.string(from: startDate)
            let endKey = dayFormatter.string(from: now)

            var rollups = try database.fetchDailyRollups(startDate: startKey, endDate: endKey)
            if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                rollups = rollups.filter { $0.sourceId.lowercased() == filterLower }
            }
            let totalTokens = rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = rollups.reduce(0.0) { $0 + $1.costUSD }

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
            let projRankings = try database.fetchProjectRankings(limit: 10, sourceId: toolFilter)

            let labelFormatter = DateFormatter()
            labelFormatter.dateFormat = (daysCount == 7) ? "E MM/dd" : "MM/dd"
            labelFormatter.timeZone = TimeZone.current

            var trendPoints: [TrendPoint] = []
            var cur = startDate
            while cur <= now {
                let key = dayFormatter.string(from: cur)
                let label = labelFormatter.string(from: cur)
                let dayRollups = rollupsByDay[key] ?? []
                let dTokens = dayRollups.reduce(0) { $0 + $1.totalTokens }
                let dCost = dayRollups.reduce(0.0) { $0 + $1.costUSD }
                trendPoints.append(TrendPoint(label: label, tokens: dTokens, costUSD: dCost))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cur) else { break }
                cur = next
            }

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings
            )

        case .pastYear:
            guard let startDate = calendar.date(byAdding: .year, value: -1, to: now) else {
                return PeriodMetrics(totalTokens: 0, totalCostUSD: 0, mostActiveTool: "None", trendPoints: [], toolDistribution: [], projectRankings: [])
            }
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone.current
            let startKey = dayFormatter.string(from: startDate)
            let endKey = dayFormatter.string(from: now)

            var rollups = try database.fetchDailyRollups(startDate: startKey, endDate: endKey)
            if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                rollups = rollups.filter { $0.sourceId.lowercased() == filterLower }
            }
            let totalTokens = rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = rollups.reduce(0.0) { $0 + $1.costUSD }

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in rollups {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + r.costUSD)
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: 10, sourceId: toolFilter)

            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "MMM yy"
            monthFormatter.timeZone = TimeZone.current

            var trendPoints: [TrendPoint] = []
            for i in (0..<12).reversed() {
                guard let monthDate = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
                let comp = calendar.dateComponents([.year, .month], from: monthDate)
                guard let y = comp.year, let m = comp.month else { continue }
                let prefix = String(format: "%04d-%02d", y, m)
                let monthLabel = monthFormatter.string(from: monthDate)

                let monthRollups = rollups.filter { $0.dayKey.hasPrefix(prefix) }
                let mTokens = monthRollups.reduce(0) { $0 + $1.totalTokens }
                let mCost = monthRollups.reduce(0.0) { $0 + $1.costUSD }
                trendPoints.append(TrendPoint(label: monthLabel, tokens: mTokens, costUSD: mCost))
            }

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings
            )

        case .year(let year):
            var rollups = try database.fetchDailyRollups(forYear: year)
            if let tool = toolFilter, !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let filterLower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                rollups = rollups.filter { $0.sourceId.lowercased() == filterLower }
            }
            let totalTokens = rollups.reduce(0) { $0 + $1.totalTokens }
            let totalCost = rollups.reduce(0.0) { $0 + $1.costUSD }

            var toolTotals: [String: (tokens: Int, costUSD: Double)] = [:]
            for r in rollups {
                let cur = toolTotals[r.sourceId] ?? (0, 0.0)
                toolTotals[r.sourceId] = (cur.tokens + r.totalTokens, cur.costUSD + r.costUSD)
            }
            let toolDist = toolTotals.map { (tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.costUSD) }
                .sorted { $0.tokens > $1.tokens }
            let mostActive = toolDist.first?.tool ?? "None"
            let projRankings = try database.fetchProjectRankings(limit: 10, sourceId: toolFilter)

            let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            var trendPoints: [TrendPoint] = []
            for m in 1...12 {
                let prefix = String(format: "%04d-%02d", year, m)
                let monthRollups = rollups.filter { $0.dayKey.hasPrefix(prefix) }
                let mTokens = monthRollups.reduce(0) { $0 + $1.totalTokens }
                let mCost = monthRollups.reduce(0.0) { $0 + $1.costUSD }
                trendPoints.append(TrendPoint(label: monthNames[m - 1], tokens: mTokens, costUSD: mCost))
            }

            return PeriodMetrics(
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                mostActiveTool: mostActive,
                trendPoints: trendPoints,
                toolDistribution: toolDist,
                projectRankings: projRankings
            )
        }
    }
}
