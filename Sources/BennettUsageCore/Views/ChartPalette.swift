import SwiftUI

/// Unified color palette for chart segments, agents, and model distributions.
///
/// Integrates curated brand colors from `AppTheme` for all 14 known agents,
/// brand-derived hues for standard model families, and a refined 16-color
/// Things 3 harmonic wheel for arbitrary keys.
public struct ChartPalette: Sendable {
    public static let shared = ChartPalette()

    private let seed: Double
    /// Per-instance memoization of `colors(for:)`, keyed by the canonical
    /// (sorted) key list. Shared by copies of the same `ChartPalette` value,
    /// so it must be thread-safe; see `Cache`.
    private let cache = Cache()

    public init(seed: Double = 0.0) {
        self.seed = seed
    }

    /// Assigns a curated, harmonic color to each key. Deterministic and session-stable.
    public func colors(for keys: [String]) -> [String: Color] {
        let sortedKeys = keys.sorted()
        if let cached = cache.value(for: sortedKeys) {
            return cached
        }
        var result: [String: Color] = [:]
        result.reserveCapacity(sortedKeys.count)
        for (index, key) in sortedKeys.enumerated() {
            let lower = key.lowercased()
            if let agentColor = AppTheme.Agent.knownColor(for: lower) {
                result[key] = agentColor
            } else if let modelColor = AppTheme.Agent.inferredModelColor(for: lower) {
                result[key] = modelColor
            } else {
                result[key] = AppTheme.Harmonic.color(for: key, index: index, seed: seed)
            }
        }
        cache.store(result, for: sortedKeys)
        return result
    }

    /// Bounded, thread-safe memoization box.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [[String]: [String: Color]] = [:]
        private var insertionOrder: [[String]] = []
        /// Upper bound on cached key lists; bounds memory if callers pass an
        /// ever-growing set of distinct key lists.
        private let capacity = 32

        func value(for key: [String]) -> [String: Color]? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ value: [String: Color], for key: [String]) {
            lock.lock()
            defer { lock.unlock() }
            if entries.updateValue(value, forKey: key) != nil { return }
            insertionOrder.append(key)
            if insertionOrder.count > capacity {
                let oldest = insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
    }
}
