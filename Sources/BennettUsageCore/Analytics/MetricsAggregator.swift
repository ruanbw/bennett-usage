import Foundation

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

public final class MetricsAggregator: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAnnualHeatmap(year: Int) async throws -> [HeatmapDayCell] {
        let rollups = try database.fetchDailyRollups(forYear: year)
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
}
