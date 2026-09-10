import Foundation

public struct UnifiedTokenRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let sourceId: String
    public let timestamp: Date
    public let dayKey: String
    public let sessionKey: String
    public let projectFolder: String?
    public let model: String
    public let provider: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    public let rawCostUSD: Double?

    public init(
        id: String,
        sourceId: String,
        timestamp: Date,
        dayKey: String? = nil,
        sessionKey: String,
        projectFolder: String?,
        model: String,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        rawCostUSD: Double? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.timestamp = timestamp
        if let dayKey = dayKey {
            self.dayKey = dayKey
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            self.dayKey = formatter.string(from: timestamp)
        }
        self.sessionKey = sessionKey
        self.projectFolder = projectFolder
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.rawCostUSD = rawCostUSD
    }
}
