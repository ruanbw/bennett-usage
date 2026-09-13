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
}
