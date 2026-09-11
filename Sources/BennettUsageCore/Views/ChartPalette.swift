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

    public init(seed: Double = Double.random(in: 0..<1)) {
        self.seed = seed
    }

    /// Assigns a color to each key. Deterministic for a given key list.
    public func colors(for keys: [String]) -> [String: Color] {
        var result: [String: Color] = [:]
        for (index, key) in keys.sorted().enumerated() {
            let hue = (seed + Double(index) * 0.618033988749895)
                .truncatingRemainder(dividingBy: 1)
            result[key] = Color(hue: hue, saturation: 0.62, brightness: 0.95)
        }
        return result
    }
}
