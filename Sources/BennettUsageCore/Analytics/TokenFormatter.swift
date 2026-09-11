import Foundation

/// Provides clean, human-readable compact formatting for token numbers (<1k, k, M, B)
/// along with exact full number string representation.
public enum TokenFormatter {
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    /// Format token integer into a compact human-friendly string (e.g. 950, 1.2k, 14.3M, 1.5B).
    public static func formatCompact(_ tokens: Int) -> String {
        let absTokens = abs(tokens)
        let sign = tokens < 0 ? "-" : ""

        if absTokens < 1_000 {
            return "\(tokens)"
        } else if absTokens < 1_000_000 {
            let val = Double(absTokens) / 1_000.0
            if roundsUpToThousand(val, maxDecimals: 1) {
                let mVal = Double(absTokens) / 1_000_000.0
                return "\(sign)\(formatValue(mVal, maxDecimals: 2))M"
            }
            return "\(sign)\(formatValue(val, maxDecimals: 1))k"
        } else if absTokens < 1_000_000_000 {
            let val = Double(absTokens) / 1_000_000.0
            let decimals = val < 10.0 ? 2 : 1
            if roundsUpToThousand(val, maxDecimals: decimals) {
                let bVal = Double(absTokens) / 1_000_000_000.0
                return "\(sign)\(formatValue(bVal, maxDecimals: 2))B"
            }
            return "\(sign)\(formatValue(val, maxDecimals: decimals))M"
        } else {
            let val = Double(absTokens) / 1_000_000_000.0
            let decimals = val < 10.0 ? 2 : 1
            return "\(sign)\(formatValue(val, maxDecimals: decimals))B"
        }
    }

    private static func formatValue(_ value: Double, maxDecimals: Int) -> String {
        let factor = pow(10.0, Double(maxDecimals))
        let rounded = (value * factor).rounded(.toNearestOrAwayFromZero) / factor
        let str: String
        if maxDecimals == 2 {
            str = String(format: "%.2f", rounded)
        } else {
            str = String(format: "%.1f", rounded)
        }

        if str.contains(".") {
            var trimmed = str
            while trimmed.hasSuffix("0") {
                trimmed.removeLast()
            }
            if trimmed.hasSuffix(".") {
                trimmed.removeLast()
            }
            return trimmed
        }
        return str
    }

    /// Returns true when the display-rounded value would read as 1000 of the current unit.
    private static func roundsUpToThousand(_ value: Double, maxDecimals: Int) -> Bool {
        let factor = pow(10.0, Double(maxDecimals))
        return (value * factor).rounded(.toNearestOrAwayFromZero) >= 1000 * factor
    }

    /// Format token integer with standard thousand commas (e.g. 14,250,000).
    public static func formatFull(_ tokens: Int) -> String {
        return numberFormatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    /// Formats both compact and tooltip strings.
    public static func formatWithTooltip(_ tokens: Int) -> (compact: String, tooltip: String) {
        let compact = formatCompact(tokens)
        let full = formatFull(tokens)
        return (compact: compact, tooltip: "\(full) tokens")
    }
}
