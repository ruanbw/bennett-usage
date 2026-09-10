import Foundation

public struct HeatmapDayCell: Identifiable, Sendable, Equatable {
    public var id: String { dayKey }
    public let date: Date
    public let dayKey: String
    public let totalTokens: Int
    public let costUSD: Double
    public let intensityLevel: Int        // 0 (none), 1 (light), 2 (moderate), 3 (high), 4 (peak)
    public let toolBreakdown: [String: Int] // sourceId -> tokens

    public init(
        date: Date,
        dayKey: String,
        totalTokens: Int,
        costUSD: Double,
        intensityLevel: Int,
        toolBreakdown: [String: Int]
    ) {
        self.date = date
        self.dayKey = dayKey
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.intensityLevel = intensityLevel
        self.toolBreakdown = toolBreakdown
    }
}
