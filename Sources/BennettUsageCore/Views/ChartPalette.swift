import SwiftUI

/// Per-launch color palette for chart segments.
///
/// A random seed is drawn once per process launch. Keys are sorted and hues
/// step around the color wheel by the golden angle, so any list of keys gets
/// visually distinct colors. Colors are stable within a session for a given
/// key list, but change on every app launch.
public struct ChartPalette: Sendable {
    public static let shared = ChartPalette()

    private let seed: Double
    /// Per-instance memoization of `colors(for:)`, keyed by the canonical
    /// (sorted) key list. Shared by copies of the same `ChartPalette` value,
    /// so it must be thread-safe; see `Cache`.
    private let cache = Cache()

    public init(seed: Double = Double.random(in: 0..<1)) {
        self.seed = seed
    }

    /// Assigns a color to each key. Deterministic for a given key list.
    public func colors(for keys: [String]) -> [String: Color] {
        let sortedKeys = keys.sorted()
        if let cached = cache.value(for: sortedKeys) {
            return cached
        }
        var result: [String: Color] = [:]
        result.reserveCapacity(sortedKeys.count)
        for (index, key) in sortedKeys.enumerated() {
            let hue = (seed + Double(index) * 0.618033988749895)
                .truncatingRemainder(dividingBy: 1)
            result[key] = Color(hue: hue, saturation: 0.62, brightness: 0.95)
        }
        cache.store(result, for: sortedKeys)
        return result
    }

    /// Bounded, thread-safe memoization box.
    ///
    /// `ChartPalette` is a `Sendable` struct and `shared` is a `static let`,
    /// so the cache cannot be a bare mutable dictionary. This reference type
    /// carries its own `NSLock` and is `@unchecked Sendable`: every read and
    /// write of `entries`/`insertionOrder` happens under `lock`, so the only
    /// reason the compiler cannot prove `Sendable` is the unchecked nature of
    /// the lock-guarded mutation (a common, well-defined pattern). Each
    /// `ChartPalette` value (and its copies) owns one box, so entries are
    /// always keyed by the same `seed` and cannot cross instances.
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
            // `updateValue` returns the previous value only if the key was
            // already present, so an existing entry never grows `insertionOrder`.
            if entries.updateValue(value, forKey: key) != nil { return }
            insertionOrder.append(key)
            if insertionOrder.count > capacity {
                let oldest = insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
    }
}
