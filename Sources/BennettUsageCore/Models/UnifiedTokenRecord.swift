import Foundation

/// Describes what a record's timestamp represents.
public enum TimestampSource: String, Sendable, Codable, CaseIterable {
    /// The timestamp was carried by the usage event itself.
    case event
    /// The timestamp was inferred from a source file's modification time.
    case sourceModified
    /// The source did not provide enough information to classify the timestamp.
    case unknown
}

public struct UnifiedTokenRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let sourceId: String
    public let timestamp: Date
    public let timestampSource: TimestampSource
    public let dayKey: String
    public let sessionKey: String
    public var projectFolder: String?
    public let model: String
    public let provider: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    /// Mutable so the sync coordinator can attach pricing in place instead of
    /// rebuilding every unpriced record (all of its Strings) field by field.
    public var rawCostUSD: Double?
    /// Fixed-format machine-readable date; pinned to Gregorian calendar so
    /// non-Gregorian user locales cannot corrupt the year. Built from date
    /// components with integer interpolation instead of a shared
    /// DateFormatter: identical output ("yyyy-MM-dd" in the current time
    /// zone) with no ICU setup, and no shared mutable formatter on the
    /// per-record sync hot path (DateFormatter is not thread-safe).
    /// `Calendar` is a value type, so each call works on a local copy of the
    /// cached base calendar. Deliberately not `String(format:)`: the printf
    /// parser costs ~12µs per call, several times a formatted conversion.
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    static func dayKey(for date: Date) -> String {
        var calendar = Self.gregorianCalendar
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        // Timestamps are real-world dates (year 1000...9999); the fallback
        // branch keeps gigantic/negative years sane without slowing the hot path.
        let y = comps.year ?? 0
        let yearStr = y >= 1000 && y <= 9999 ? String(y) : String(format: "%04d", y)
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        return "\(yearStr)-\(m < 10 ? "0\(m)" : "\(m)")-\(d < 10 ? "0\(d)" : "\(d)")"
    }

    public init(
        id: String,
        sourceId: String,
        timestamp: Date,
        timestampSource: TimestampSource = .event,
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
        self.timestampSource = timestampSource
        if let dayKey = dayKey {
            self.dayKey = dayKey
        } else {
            self.dayKey = Self.dayKey(for: timestamp)
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

    private enum CodingKeys: String, CodingKey {
        case id, sourceId, timestamp, timestampSource, dayKey, sessionKey, projectFolder
        case model, provider, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case rawCostUSD
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceId = try container.decode(String.self, forKey: .sourceId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        timestampSource = try container.decodeIfPresent(TimestampSource.self, forKey: .timestampSource) ?? .event
        dayKey = try container.decode(String.self, forKey: .dayKey)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        projectFolder = try container.decodeIfPresent(String.self, forKey: .projectFolder)
        model = try container.decode(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try container.decode(Int.self, forKey: .cacheWriteTokens)
        rawCostUSD = try container.decodeIfPresent(Double.self, forKey: .rawCostUSD)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(timestampSource, forKey: .timestampSource)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(projectFolder, forKey: .projectFolder)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encodeIfPresent(rawCostUSD, forKey: .rawCostUSD)
    }
}
