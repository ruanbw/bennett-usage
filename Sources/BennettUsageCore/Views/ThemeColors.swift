import SwiftUI
import AppKit

/// The appearance preference shared by the app's native and SwiftUI surfaces.
///
/// The default is deliberately dark to match the approved Penpot design. A
/// missing or invalid persisted value is treated as dark as well, so a
/// malformed preference can never leave the app without a usable appearance.
public enum AppThemeMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light

    /// Stable key used by the settings UI and the app's UserDefaults store.
    public static let storageKey = "bennett_theme_mode"
    /// Backward-compatible spelling for callers that used the defaults name.
    public static let userDefaultsKey = storageKey
    public static let defaultMode: Self = .dark

    public var id: String { rawValue }

    /// Stable localization key, suitable for a localization system that loads
    /// strings by key rather than through `LocalizedKey`.
    public var titleKey: String {
        switch self {
        case .system: return "theme.system"
        case .dark: return "theme.dark"
        case .light: return "theme.light"
        }
    }

    /// Localized title for the built-in English and Chinese managers. The
    /// stable `titleKey` remains available for dynamically registered packs.
    public func localizedTitle(localization: LocalizationManager) -> String {
        let isChinese = localization.effectiveLanguage == .zh
        switch self {
        case .system: return isChinese ? "跟随系统" : "Follow System"
        case .dark: return isChinese ? "深色" : "Dark"
        case .light: return isChinese ? "浅色" : "Light"
        }
    }

    /// SwiftUI's nil value intentionally follows the host appearance.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// The corresponding AppKit appearance, or nil to follow the system.
    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    /// Alias with an explicit name for code that distinguishes native from
    /// SwiftUI appearance values.
    public var nativeAppearance: NSAppearance? { appearance }

    /// Reads a persisted mode, falling back to the approved dark default.
    public static func stored(in userDefaults: UserDefaults = .standard) -> Self {
        guard let rawValue = userDefaults.string(forKey: storageKey),
              let mode = Self(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    /// Applies the mode to an AppKit application, including native windows.
    @MainActor
    public func apply(to application: NSApplication) {
        application.appearance = nativeAppearance
    }
}

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

    // MARK: - Semantic Typography

    /// Shared type ramp for the menu-bar and dashboard surfaces. Keeping these
    /// roles semantic makes it possible to tune density without changing the
    /// information hierarchy of an individual screen.
    public enum Typography {
        /// Dashboard hierarchy: the compact total is deliberately dominant and
        /// exact values remain tabular, secondary metadata.
        public static let heroMetric = Font.system(size: 48, weight: .bold, design: .rounded)
        public static let heroSpend = Font.system(size: 28, weight: .semibold, design: .rounded)
        public static let contextTitle = Font.system(size: 24, weight: .bold, design: .rounded)
        public static let sectionTitle = Font.system(size: 16, weight: .semibold)
        public static let metricValue = Font.system(size: 15, weight: .semibold, design: .rounded)
        public static let supportingValue = Font.system(size: 17, weight: .semibold, design: .rounded)
        public static let exactValue = Font.system(size: 12, weight: .medium, design: .monospaced)
        public static let label = Font.system(size: 11, weight: .medium)
        public static let caption = Font.system(size: 11)

        /// Section eyebrows replace the old "icon + title" pattern. A tracked,
        /// uppercase micro-label carries the grouping without decorating every
        /// heading with a pictogram.
        public static let eyebrow = Font.system(size: 10, weight: .semibold)
        public static let pageTitle = Font.system(size: 19, weight: .bold)
        public static let rowTitle = Font.system(size: 13, weight: .medium)
        public static let rowDetail = Font.system(size: 11)
        /// Dense numeric readouts inside tables and lists.
        public static let tabular = Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    // MARK: - Layout & Controls

    /// Density tokens shared by all three native surfaces.
    public enum Layout {
        public static let canvasPadding: CGFloat = 24
        public static let sectionSpacing: CGFloat = 20
        public static let cardPadding: CGFloat = 18
        public static let compactSpacing: CGFloat = 10
        public static let hairline: CGFloat = 0.5

        /// Gaps inside a continuous container (the Dashboard conclusion panel,
        /// Settings groups). Continuous containers separate their children with
        /// hairlines rather than by repeating a card border.
        public static let groupGap: CGFloat = 14
        public static let cellPadding: CGFloat = 16
        public static let rowHeight: CGFloat = 44
    }

    public enum Radius {
        public static let card: CGFloat = 12
        /// The single enclosing container for a screen region. Slightly tighter
        /// than `card` so grouped panels read as one object.
        public static let panel: CGFloat = 10
        public static let control: CGFloat = 8
        public static let pill: CGFloat = 999

        public enum Settings {
            public static let sidebarWidth: CGFloat = 176
            public static let headerHeight: CGFloat = 64
            public static let privacyFooterHeight: CGFloat = 30
            public static let contentPadding: CGFloat = 20
        }
    }

    public enum Control {
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 32
        public static let icon: CGFloat = 13
    }

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

        /// One continuous container that groups a whole screen region. Regions
        /// separated by this surface are separated by whitespace and hairlines
        /// instead of by repeating a bordered card, which is what previously
        /// made every surface read as an identical tile in a card wall.
        public static let panel = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#252528")

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

        /// Floating popovers, tooltips, controls, and elevated modal panels.
        /// Kept dynamic because the Penpot popover and settings chrome follow
        /// the system appearance independently of the dashboard canvas.
        public static let elevated = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#2C2C30")
    }

    // MARK: - Data Marks

    /// Colors used by data marks, kept separate from `Status` so a categorical
    /// agent color can never double as an interaction or state color.
    public enum Data {
        /// The empty portion of a proportional bar. Categorical hues are drawn
        /// on top of this neutral track rather than as a full-bleed fill, so one
        /// dominant agent color no longer owns the whole screen.
        public static let track = Color.dynamic(lightHex: "#000000", darkHex: "#FFFFFF", lightAlpha: 0.07, darkAlpha: 0.10)

        /// A single-series mark (one total, no category split). Neutral by
        /// default so the eye reads shape and position, not hue.
        public static let series = Color.dynamic(lightHex: "#0066CC", darkHex: "#2997FF")
        public static let seriesMuted = Color.dynamic(lightHex: "#0066CC", darkHex: "#2997FF", lightAlpha: 0.28, darkAlpha: 0.42)
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

    /// Color roles are strict and do not overlap:
    ///
    /// - `Chrome` colors every piece of interface furniture: selection, focus,
    ///   links, active controls. There is exactly one accent.
    /// - `Status` colors a *state* only: success, warning, destructive. A color
    ///   here never appears on a value that is not a state.
    /// - `Agent` / `Harmonic` / `Data.series` color a *category* on a data mark
    ///   only. A categorical hue never colors an icon, a sidebar row, a section
    ///   heading, or a button.
    ///
    /// Before this rule the same amber meant "Pi Agent" in a legend, "cache
    /// write" in the composition bar, "caution" in Settings, and "project" in a
    /// heading icon, so no hue on screen carried a readable meaning.
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

    /// Interface furniture. One accent, used for anything the user can act on
    /// and for anything that reports its own selection state.
    public enum Chrome {
        public static let accent = Status.accent
        /// A filled accent, for a selected segmented segment or primary button.
        public static let accentFill = Status.accent
        /// A low-emphasis wash of the accent, for a selected row background.
        public static let accentWash = Surface.selected
        /// Icons and glyphs that carry no state of their own.
        public static let glyph = Text.secondary
        public static let glyphActive = Status.accent
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
        /// Semantic series colors used when category identity is not the data
        /// subject. Agent-facing charts continue to use `Agent` below.
        public enum Series {
            public static let input = Status.accent
            public static let output = Agent.claude
            public static let cacheRead = Status.success
            public static let cacheWrite = Status.warning
        }

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

    // MARK: - Agent Brand Palette (All 18 Agents)

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

        // 16. Goose: Golden Yellow
        public static let goose = Color.dynamic(lightHex: "#CA8A04", darkHex: "#FDE047")

        // 17. Crush: Charm Magenta
        public static let crush = Color.dynamic(lightHex: "#E34D8A", darkHex: "#F472B6")

        // 18. Kimi Code: Moonlit Violet
        public static let kimi = Color.dynamic(lightHex: "#6D28D9", darkHex: "#A78BFA")

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
            case "goose": return goose
            case "crush": return crush
            case "kimi": return kimi
            default: return nil
            }
        }

        /// Map of all 18 curated agents.
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
            "continue": `continue`,
            "goose": goose,
            "crush": crush,
            "kimi": kimi
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
