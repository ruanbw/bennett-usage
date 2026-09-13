import Foundation

/// Trailing-edge throttle decision logic for bursty data-update reloads.
///
/// Each full reload re-aggregates every record in range (~194 ms), so bursts
/// while agents are active collapse to at most one reload per `interval`.
/// The previous dashboard throttle *dropped* in-window notifications, which
/// starved the UI under continuous activity and made counts look stale or
/// jumpy; this schedules exactly one trailing reload instead.
///
/// Extracted as a pure value (dates injectable) so the rules are unit
/// tested; callers own the sleep/trailer orchestration.
public struct TrailingThrottle: Sendable {
    public let interval: TimeInterval
    private var lastRun: Date = .distantPast
    private var trailerScheduled = false

    public init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    /// True when the caller should reload immediately and record the run.
    public mutating func shouldRunImmediately(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastRun) >= interval else { return false }
        lastRun = now
        return true
    }

    /// True when the caller should schedule the single trailing reload.
    /// Collapses concurrent in-window requests into one trailer.
    public mutating func shouldScheduleTrailer() -> Bool {
        guard !trailerScheduled else { return false }
        trailerScheduled = true
        return true
    }

    /// Records a fired trailer so the next burst can schedule again.
    public mutating func trailerFired(at now: Date = Date()) {
        trailerScheduled = false
        lastRun = now
    }
}
