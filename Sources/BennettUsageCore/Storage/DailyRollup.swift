import Foundation

public struct DailyRollup: Identifiable, Sendable, Codable, Equatable {
    public var id: String { "\(dayKey)_\(sourceId)" }
    public let dayKey: String
    public let sourceId: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let costUSD: Double

    public init(
        dayKey: String,
        sourceId: String,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        costUSD: Double
    ) {
        self.dayKey = dayKey
        self.sourceId = sourceId
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.costUSD = costUSD
    }
}
