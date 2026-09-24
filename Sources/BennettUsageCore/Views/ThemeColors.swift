import SwiftUI
import AppKit

// MARK: - Dynamic Color Extensions for AppKit & SwiftUI

extension NSColor {
    /// Convenience initializer to parse 6-character hex strings (with or without `#`).
    public convenience init(hex: String, alpha: Double = 1.0) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}

extension Color {
    /// Creates a dynamic SwiftUI Color that adapts between macOS Light and Dark mode appearances.
    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }))
    }

    /// Convenience initializer using hex strings and opacities for light and dark modes.
    public static func dynamic(
        lightHex: String,
        darkHex: String,
        lightAlpha: Double = 1.0,
        darkAlpha: Double = 1.0
    ) -> Color {
        let light = NSColor(hex: lightHex, alpha: lightAlpha)
        let dark = NSColor(hex: darkHex, alpha: darkAlpha)
        return dynamic(light: light, dark: dark)
    }
}

// MARK: - AppTheme: Things 3 / Apple HIG Minimalist Design Tokens

/// Unified semantic design token system for Bennett Usage.
///
/// Follows Apple Human Interface Guidelines and Things 3 minimalist aesthetic:
/// - Light Mode: Off-white canvas, crisp white card surfaces, delicate warm grays, high-legibility charcoal text.
/// - Dark Mode: Deep velvety graphite canvas (#1C1C1E), subtle elevation, crisp off-white typography.
/// - Non-fatiguing, low-saturation, calm, editorial contrast.
public enum AppTheme {

    // MARK: - Canvas & Surfaces

    public enum Canvas {
        /// Base window / background canvas.
        /// Light: Warm off-white (#F5F5F7), Dark: Velvety graphite (#1C1C1E).
        public static let background = Color.dynamic(lightHex: "#F5F5F7", darkHex: "#1C1C1E")
    }

    public enum Surface {
        /// Primary card / container surface.
        /// Light: Pure white (#FFFFFF), Dark: Elevated warm graphite (#262629).
        public static let primary = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#262629")

        /// Subtle container / inset well for grouped rows or stat pods.
        /// Light: Delicate warm gray (#EFEFF1), Dark: Subtle well (#2F2F34).
        public static let subtle = Color.dynamic(lightHex: "#EFEFF1", darkHex: "#2F2F34")

        /// Interactive row / pill hover overlay.
        public static let hover = Color.dynamic(
            lightHex: "#000000", darkHex: "#FFFFFF",
            lightAlpha: 0.04, darkAlpha: 0.06
        )

        /// Interactive selected item background.
        public static let selected = Color.dynamic(
            lightHex: "#0066CC", darkHex: "#2997FF",
            lightAlpha: 0.10, darkAlpha: 0.16
        )

        /// Floating popovers, tooltips, and elevated modal panels.
        public static let elevated = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#2C2C30")
    }

    // MARK: - Typography

    public enum Text {
        /// High-contrast primary reading text.
        /// Light: Deep charcoal (#1D1D1F), Dark: Crisp off-white (#F5F5F7).
        public static let primary = Color.dynamic(lightHex: "#1D1D1F", darkHex: "#F5F5F7")

        /// Calm secondary text for subtitles, units, and timestamps.
        /// Light: Muted graphite (#6E6E73), Dark: Silver gray (#98989D).
        public static let secondary = Color.dynamic(lightHex: "#6E6E73", darkHex: "#98989D")

        /// Tertiary text for captions, table headers, and axis markers.
        /// Light: Warm graphite (#76767B), Dark: Light slate (#8C8C8F).
        public static let tertiary = Color.dynamic(lightHex: "#76767B", darkHex: "#8C8C8F")

        /// Quaternary text for inactive placeholders and disabled labels.
        public static let quaternary = Color.dynamic(lightHex: "#AEAEC2", darkHex: "#48484A")
    }

    // MARK: - Hairlines & Borders

    public enum Border {
        /// Crisp 0.5pt divider between list items and header sections.
        public static let divider = Color.dynamic(
            lightHex: "#000000", darkHex: "#FFFFFF",
            lightAlpha: 0.08, darkAlpha: 0.09
        )

        /// Subtle card boundary stroke.
        public static let subtle = Color.dynamic(
            lightHex: "#000000", darkHex: "#FFFFFF",
            lightAlpha: 0.06, darkAlpha: 0.08
        )

        /// Focused / active element border.
        public static let focus = Color.dynamic(lightHex: "#0066CC", darkHex: "#2997FF")
    }

    // MARK: - Status & Accent

    public enum Status {
        /// macOS refined primary interactive blue.
        public static let accent = Color.dynamic(lightHex: "#0066CC", darkHex: "#2997FF")

        /// Token spend / health OK / success state:
        /// Light: Botanical forest emerald (#15803D), Dark: Luminous mint emerald (#34D399).
        public static let success = Color.dynamic(lightHex: "#15803D", darkHex: "#34D399")

        /// Warning / caution state:
        /// Light: Warm amber (#D97706), Dark: Luminous amber (#FBBF24).
        public static let warning = Color.dynamic(lightHex: "#D97706", darkHex: "#FBBF24")

        /// Error / destructive state:
        /// Light: Crimson coral (#DC2626), Dark: Soft coral red (#F87171).
        public static let error = Color.dynamic(lightHex: "#DC2626", darkHex: "#F87171")
    }

    // MARK: - Project Rank Medals

    public enum Rank {
        /// 1st place: Refined warm gold.
        public static let gold = Color.dynamic(lightHex: "#D97706", darkHex: "#F59E0B")

        /// 2nd place: Slate silver platinum.
        public static let silver = Color.dynamic(lightHex: "#64748B", darkHex: "#94A3B8")

        /// 3rd place: Warm copper bronze.
        public static let bronze = Color.dynamic(lightHex: "#B45309", darkHex: "#D97706")

        public static func color(for rank: Int) -> Color {
            switch rank {
            case 1: return gold
            case 2: return silver
            case 3: return bronze
            default: return Text.tertiary
            }
        }
    }

    // MARK: - Heatmap 5-Level Intensity Scale

    public enum Heatmap {
        /// Level 0: Zero token usage (empty day recess).
        /// Light: Warm soft recess (#E8E9ED), Dark: Velvety graphite recess (#2C2C31).
        public static let level0 = Color.dynamic(lightHex: "#E8E9ED", darkHex: "#2C2C31")

        /// Level 1: Low activity (delicate sea-mint wash).
        public static let level1 = Color.dynamic(lightHex: "#A7F3D0", darkHex: "#114732")

        /// Level 2: Moderate activity (calm leaf green).
        public static let level2 = Color.dynamic(lightHex: "#4ADE80", darkHex: "#157F54")

        /// Level 3: High activity (rich vibrant emerald).
        public static let level3 = Color.dynamic(lightHex: "#16A34A", darkHex: "#1EB878")

        /// Level 4: Peak activity (deep forest jewel in light mode, radiant mint jewel in dark mode).
        public static let level4 = Color.dynamic(lightHex: "#15803D", darkHex: "#34D399")

        public static func color(for intensity: Int) -> Color {
            switch intensity {
            case 1: return level1
            case 2: return level2
            case 3: return level3
            case 4: return level4
            default: return level0
            }
        }
    }

    // MARK: - Charts & Trends

    public enum Chart {
        /// Primary trend line.
        public static let primaryLine = Color.dynamic(lightHex: "#2563EB", darkHex: "#3B82F6")

        /// Area gradient start (top).
        public static let primaryAreaStart = Color.dynamic(
            lightHex: "#2563EB", darkHex: "#3B82F6",
            lightAlpha: 0.22, darkAlpha: 0.32
        )

        /// Area gradient end (bottom).
        public static let primaryAreaEnd = Color.dynamic(
            lightHex: "#2563EB", darkHex: "#3B82F6",
            lightAlpha: 0.01, darkAlpha: 0.02
        )

        public static var primaryAreaGradient: LinearGradient {
            LinearGradient(
                colors: [primaryAreaStart, primaryAreaEnd],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Subtle chart gridline.
        public static let gridline = Color.dynamic(
            lightHex: "#000000", darkHex: "#FFFFFF",
            lightAlpha: 0.05, darkAlpha: 0.06
        )
    }

    // MARK: - Agent Brand Palette (All 15 Agents)

    public enum Agent {
        // 1. Claude (Anthropic): Terracotta Sienna
        public static let claude = Color.dynamic(lightHex: "#CC5C36", darkHex: "#E07A5F")

        // 2. Cursor: Sky Cerulean
        public static let cursor = Color.dynamic(lightHex: "#0284C7", darkHex: "#38BDF8")

        // 3. Codex (OpenAI): Signature OpenAI Emerald
        public static let codex = Color.dynamic(lightHex: "#0D9468", darkHex: "#10B981")

        // 4. Gemini (Google): Celestial Ultramarine
        public static let gemini = Color.dynamic(lightHex: "#4361EE", darkHex: "#6B8AFF")

        // 5. Copilot (GitHub): Indigo Iris
        public static let copilot = Color.dynamic(lightHex: "#6366F1", darkHex: "#818CF8")

        // 6. Trae (ByteDance): Ocean Cyan Teal
        public static let trae = Color.dynamic(lightHex: "#0891B2", darkHex: "#22D3EE")

        // 7. DSH (DeepSeek Harness): Cobalt Sapphire
        public static let dsh = Color.dynamic(lightHex: "#1D4ED8", darkHex: "#60A5FA")

        // 8. Pi Agent: Amber Gold
        public static let pi = Color.dynamic(lightHex: "#D97706", darkHex: "#FBBF24")

        // 9. Oh My Pi: Sunset Tangerine
        public static let omp = Color.dynamic(lightHex: "#EA580C", darkHex: "#FB923C")

        // 10. Cline: Sea Pine Teal
        public static let cline = Color.dynamic(lightHex: "#0F766E", darkHex: "#2DD4BF")

        // 11. Roo Code: Rose Carmine
        public static let roo = Color.dynamic(lightHex: "#E11D48", darkHex: "#FB7185")

        // 12. Qwen (Alibaba): Royal Amethyst
        public static let qwen = Color.dynamic(lightHex: "#7E22CE", darkHex: "#C084FC")

        // 13. OpenCode: Slate Steel
        public static let opencode = Color.dynamic(lightHex: "#475569", darkHex: "#94A3B8")

        // 14. Antigravity: Cosmic Orchid
        public static let antigravity = Color.dynamic(lightHex: "#9333EA", darkHex: "#D8B4FE")

        // 15. Continue CLI: Signal Blue
        public static let `continue` = Color.dynamic(lightHex: "#2563EB", darkHex: "#60A5FA")

        /// Lookup curated color by agent source ID.
        public static func knownColor(for id: String) -> Color? {
            switch id.lowercased() {
            case "claude": return claude
            case "cursor": return cursor
            case "codex": return codex
            case "gemini": return gemini
            case "copilot": return copilot
            case "trae": return trae
            case "dsh": return dsh
            case "pi": return pi
            case "omp": return omp
            case "cline": return cline
            case "roo": return roo
            case "qwen": return qwen
            case "opencode": return opencode
            case "antigravity": return antigravity
            case "continue": return `continue`
            default: return nil
            }
        }

        /// Map of all 15 curated agents.
        public static let allMap: [String: Color] = [
            "claude": claude,
            "cursor": cursor,
            "codex": codex,
            "gemini": gemini,
            "copilot": copilot,
            "trae": trae,
            "dsh": dsh,
            "pi": pi,
            "omp": omp,
            "cline": cline,
            "roo": roo,
            "qwen": qwen,
            "opencode": opencode,
            "antigravity": antigravity,
            "continue": `continue`
        ]

        /// Infers agent brand color for arbitrary model names (e.g. claude-3-5-sonnet -> claude).
        public static func inferredModelColor(for model: String) -> Color? {
            let lower = model.lowercased()
            if lower.contains("claude") { return claude }
            if lower.contains("gpt") || lower.contains("o1") || lower.contains("o3") { return codex }
            if lower.contains("gemini") { return gemini }
            if lower.contains("deepseek") { return dsh }
            if lower.contains("qwen") { return qwen }
            return nil
        }
    }

    // MARK: - Harmonic Palette for Arbitrary Keys (Models, Categories)

    public enum Harmonic {
        /// Curated 16-color harmonic wheel with calm saturation and balanced luminance.
        public static let palette: [Color] = [
            Color.dynamic(lightHex: "#E06D53", darkHex: "#EA8268"), // Coral Rose
            Color.dynamic(lightHex: "#D97757", darkHex: "#E28766"), // Terracotta
            Color.dynamic(lightHex: "#D97706", darkHex: "#F59E0B"), // Warm Amber
            Color.dynamic(lightHex: "#CA8A04", darkHex: "#EAB308"), // Honey Gold
            Color.dynamic(lightHex: "#65A30D", darkHex: "#84CC16"), // Sage Olive
            Color.dynamic(lightHex: "#0D9468", darkHex: "#10B981"), // Forest Emerald
            Color.dynamic(lightHex: "#0D9488", darkHex: "#14B8A6"), // Pine Teal
            Color.dynamic(lightHex: "#0891B2", darkHex: "#06B6D4"), // Ocean Cyan
            Color.dynamic(lightHex: "#0284C7", darkHex: "#38BDF8"), // Sky Cerulean
            Color.dynamic(lightHex: "#2563EB", darkHex: "#60A5FA"), // Royal Cobalt
            Color.dynamic(lightHex: "#4F46E5", darkHex: "#818CF8"), // Celestial Indigo
            Color.dynamic(lightHex: "#7C3AED", darkHex: "#A78BFA"), // Iris Violet
            Color.dynamic(lightHex: "#9333EA", darkHex: "#C084FC"), // Royal Purple
            Color.dynamic(lightHex: "#C026D3", darkHex: "#E879F9"), // Orchid Magenta
            Color.dynamic(lightHex: "#E11D48", darkHex: "#FB7185"), // Carmine Rose
            Color.dynamic(lightHex: "#475569", darkHex: "#94A3B8")  // Slate Steel
        ]

        /// Deterministic color for an arbitrary key, stable across app sessions.
        public static func color(for key: String, index: Int? = nil, seed: Double = 0.0) -> Color {
            let offset = Int(abs(seed * 1000).rounded())
            if let index = index {
                let paletteIndex = (index + offset) % palette.count
                return palette[paletteIndex]
            }
            // Deterministic hash based on string content
            var hash: Int = 5381
            for byte in key.utf8 {
                hash = ((hash << 5) &+ hash) &+ Int(byte)
            }
            let paletteIndex = (abs(hash) + offset) % palette.count
            return palette[paletteIndex]
        }
    }
}
