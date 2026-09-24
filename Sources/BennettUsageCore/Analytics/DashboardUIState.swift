import Foundation

/// Presentation phases for a dashboard data load. These phases describe only
/// what the view currently has; they do not assert that any adapter or the full
/// source set synchronized successfully.
public enum DashboardLoadState: String, CaseIterable, Equatable, Sendable, CustomStringConvertible {
    case loading
    case loaded
    case empty
    case stale
    case error
    case updating

    public var description: String {
        switch self {
        case .loading:
            return "Loading usage"
        case .loaded:
            return "Usage loaded"
        case .empty:
            return "No usage yet"
        case .stale:
            return "Showing cached usage"
        case .error:
            return "Usage could not be loaded"
        case .updating:
            return "Updating usage"
        }
    }
}

/// An explicit proof, supplied by the sync owner, that a refresh completed
/// successfully. Keeping this separate from analytics loading prevents a
/// successful database query from being reported as a successful source sync.
public struct LastSuccessfulRefresh: Equatable, Sendable {
    public let completedAt: Date

    public init(completedAt: Date) {
        self.completedAt = completedAt
    }

    public func formatted(
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(completedAt))
        if elapsed < 60 {
            return "Synced just now"
        }

        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "Synced \(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }

        let hours = Int(elapsed / 3_600)
        if hours < 24 {
            return "Synced \(hours) \(hours == 1 ? "hour" : "hours") ago"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return "Synced on \(formatter.string(from: completedAt))"
    }
}

/// Source-sync facts for presentation. `lastSuccessful` is only populated from
/// a known successful refresh; a partial adapter failure remains in
/// `partialFailure` and must not be promoted to `lastSuccessful` by this type.
public struct SyncFreshnessModel: Equatable, Sendable {
    public let lastChecked: Date?
    public let lastSuccessful: LastSuccessfulRefresh?
    public let isRefreshing: Bool
    public let partialFailure: String?

    public init(
        lastChecked: Date? = nil,
        lastSuccessful: LastSuccessfulRefresh? = nil,
        isRefreshing: Bool = false,
        partialFailure: String? = nil
    ) {
        self.lastChecked = lastChecked
        self.lastSuccessful = lastSuccessful
        self.isRefreshing = isRefreshing
        self.partialFailure = Self.normalizedDescription(partialFailure)
    }

    public static let unknown = Self()

    public var hasSuccessfulRefresh: Bool {
        lastSuccessful != nil
    }

    public func lastSuccessfulDescription(
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        lastSuccessful?.formatted(relativeTo: now, calendar: calendar) ?? "Not synced yet"
    }

    private static func normalizedDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A small menu-bar-friendly snapshot. An absent `today` array means the trend
/// was not supplied; an empty array means the caller supplied an empty trend.
public struct QuickGlanceSnapshot: Equatable, Sendable {
    public let summary: TodaySummary
    public let today: [TrendPoint]?
    public let freshness: SyncFreshnessModel

    public init(
        summary: TodaySummary,
        today: [TrendPoint]? = nil,
        freshness: SyncFreshnessModel = .unknown
    ) {
        self.summary = summary
        self.today = today
        self.freshness = freshness
    }

    public var hasUsage: Bool {
        summary.totalTokens > 0
    }
}

/// A value-type contract for dashboard presentation state.
///
/// The state deliberately contains only data the presentation layer already
/// has: the latest analytics snapshot, caller-supplied sync freshness, and
/// optional user-facing error/retry text. Loading analytics never infers or
/// invents a successful source refresh.
public struct DashboardUIState: Equatable, Sendable {
    public typealias Phase = DashboardLoadState

    public private(set) var phase: DashboardLoadState
    public private(set) var periodMetrics: PeriodMetrics?
    public private(set) var todaySummary: TodaySummary?
    public private(set) var freshness: SyncFreshnessModel
    public private(set) var errorDescription: String?
    public private(set) var retryDescription: String?

    public init(freshness: SyncFreshnessModel = .unknown) {
        self.phase = .loading
        self.periodMetrics = nil
        self.todaySummary = nil
        self.freshness = freshness
        self.errorDescription = nil
        self.retryDescription = nil
    }

    /// The successful refresh is always sourced from `freshness`; it is never
    /// inferred by a dashboard load transition.
    public var lastSuccessfulRefresh: LastSuccessfulRefresh? {
        freshness.lastSuccessful
    }

    /// Compatibility-friendly date view of the last known successful refresh.
    public var lastSuccessfulSync: Date? {
        lastSuccessfulRefresh?.completedAt
    }

    public var stateDescription: String {
        phase.description
    }

    /// Whether a successful analytics snapshot is available, including a
    /// successful snapshot whose token totals are zero.
    public var hasSnapshot: Bool {
        periodMetrics != nil
    }

    public var hasUsage: Bool {
        (periodMetrics?.totalTokens ?? 0) > 0 || (todaySummary?.totalTokens ?? 0) > 0
    }

    public var isBusy: Bool {
        phase == .loading || phase == .updating
    }

    public var canRetry: Bool {
        retryDescription != nil
    }

    public mutating func updateFreshness(_ freshness: SyncFreshnessModel) {
        self.freshness = freshness
    }

    /// Starts an uncached load. An existing snapshot is preserved and marked
    /// stale instead of being hidden. Use ``beginUpdating()`` for a refresh of
    /// an already available snapshot.
    public mutating func beginLoading() {
        errorDescription = nil
        retryDescription = nil
        phase = hasSnapshot ? .stale : .loading
    }

    /// Starts a background refresh, retaining the currently displayable data
    /// until the analytics load completes. Source-sync freshness is separate.
    public mutating func beginUpdating() {
        errorDescription = nil
        retryDescription = nil
        phase = hasSnapshot ? .updating : .loading
    }

    /// Installs an existing snapshot as cached data without asserting that a
    /// refresh occurred while installing it.
    public mutating func useCached(
        periodMetrics: PeriodMetrics,
        todaySummary: TodaySummary? = nil
    ) {
        self.phase = .stale
        self.periodMetrics = periodMetrics
        self.todaySummary = todaySummary
        self.errorDescription = nil
        self.retryDescription = nil
    }

    /// Completes an analytics load or refresh. A nil `todaySummary` preserves
    /// an existing today snapshot, which is useful when only period metrics
    /// were fetched. This transition does not change `freshness`.
    public mutating func loadSucceeded(
        periodMetrics: PeriodMetrics,
        todaySummary: TodaySummary? = nil
    ) {
        self.periodMetrics = periodMetrics
        if let todaySummary {
            self.todaySummary = todaySummary
        }
        self.errorDescription = nil
        self.retryDescription = nil
        phase = periodMetrics.totalTokens > 0 ? .loaded : .empty
    }

    /// Records a failed analytics load. When a snapshot is available it becomes
    /// stale; otherwise the state is an error. Both descriptions are optional
    /// so a presenter can render a minimal message, a retry action, or both.
    public mutating func loadFailed(
        errorDescription: String? = nil,
        retryDescription: String? = "Retry"
    ) {
        self.errorDescription = Self.normalizedDescription(errorDescription)
        self.retryDescription = Self.normalizedDescription(retryDescription)
        phase = hasSnapshot ? .stale : .error
    }

    /// Clears transient failure text and starts the appropriate retry state.
    public mutating func retry() {
        errorDescription = nil
        retryDescription = nil
        phase = hasSnapshot ? .updating : .loading
    }

    /// Returns to the initial, data-free loading state and clears freshness.
    public mutating func reset() {
        self = Self()
    }

    public func lastSuccessfulSyncDescription(
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        lastSuccessfulRefresh?.formatted(relativeTo: now, calendar: calendar) ?? "Not synced yet"
    }

    /// Formats sync metadata deterministically for presentation and tests.
    /// Dates in the future are treated as "just now" to tolerate clock skew.
    public static func formatLastSuccessfulSync(
        _ date: Date?,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        date.map {
            LastSuccessfulRefresh(completedAt: $0)
                .formatted(relativeTo: now, calendar: calendar)
        } ?? "Not synced yet"
    }

    private static func normalizedDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
