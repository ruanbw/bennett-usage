import Foundation

public struct BennettUsageCore {
    /// Fallback marketing version for executables that run outside an app
    /// bundle (tests, `swift run`). A packaged build reports the version the
    /// packaging script stamped into `CFBundleShortVersionString` instead —
    /// see `UpdateChecker.bundledVersion(bundle:)`.
    public static let version = "1.6.0"
}

/// A privacy-safe description of an adapter failure. Error details remain in
/// the existing diagnostic log, while persisted/observable status contains only
/// the source and the stage that failed.
public struct SyncFailureSummary: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case fetch
        case completeSnapshot
        case persistence
    }

    public let sourceId: String
    public let stage: Stage

    public init(sourceId: String, stage: Stage) {
        self.sourceId = sourceId
        self.stage = stage
    }
}

/// An actor-owned snapshot of the latest logical sync run.
public struct SyncStatus: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case idle
        case syncing
    }

    public let phase: Phase
    public let lastAttemptAt: Date?
    public let lastSuccessfulAt: Date?
    public let failures: [SyncFailureSummary]

    public init(
        phase: Phase = .idle,
        lastAttemptAt: Date? = nil,
        lastSuccessfulAt: Date? = nil,
        failures: [SyncFailureSummary] = []
    ) {
        self.phase = phase
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.failures = failures
    }
}

extension Notification.Name {
    public static let bennettUsageDataDidUpdate = Notification.Name("bennettUsageDataDidUpdate")
    public static let bennettUsageSyncStatusDidChange = Notification.Name("bennettUsageSyncStatusDidChange")
    /// Posted by the ⌘1–⌘5 menu items with the zero-based range index.
    public static let bennettUsageRangeShortcut = Notification.Name("bennettUsageRangeShortcut")
}
