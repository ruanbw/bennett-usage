# UI/UX Minimalist Refactoring Specification (Things 3 & Apple HIG Style)

- **Date**: 2026-09-20
- **Target Platform**: macOS 14.0+ (Sonoma, Sequoia)
- **Tech Stack**: Swift 6, SwiftUI, Swift Charts, AppKit
- **Repository**: `bennett-usage`
- **Application Type**: Native macOS Menu Bar Popover + Standalone Dashboard Window + Settings Sheet
- **Design Inspiration**: Things 3 (breathable editorial rhythm, cardless whitespace grouping, typography-first hierarchy) & Apple Human Interface Guidelines (native materials, dynamic light/dark contrast, refined micro-interactions)

---

## 1. Executive Summary & Goals

### 1.1 Overview
This specification defines the complete UI/UX refactoring of `bennett-usage` into a modern, minimalist native macOS experience. 

The current interface suffers from common desktop dashboard issues: heavy card-in-card nesting, intrusive dark/light border strokes, cartoonish emoji medals (🥇🥈🥉), screen-consuming radial donut charts, and high-saturation random colors that change on each launch.

This refactoring transitions the entire app—**Dashboard Window**, **Menu Bar Popover**, and **Settings Sheet**—to a **Things 3 pure editorial aesthetic**:
1. **Cardless Breathing Layout**: Eliminate multi-level card borders; use 24–36pt natural whitespace and 0.5pt delicate hairlines.
2. **Unified Light/Dark Design Tokens (`ThemeColors.swift`)**: Introduce system-adaptive dynamic colors with high-contrast, non-fatiguing typography and curated brand colors for all 14 supported agents.
3. **Data-Ink Ratio Optimization**: Replace heavy donut charts with sleek **Horizontal Segmented Distribution Bars** and compact contributor ranking lists.
4. **Editorial Typography**: Heroic SF Pro Rounded tabular figures for primary numbers, quiet secondary subtitles, and classical `01`, `02`, `03` project rankings.
5. **Lightweight Menu Bar Popover**: Frosted macOS material backdrop with a mini distribution bar and clean cardless metrics.
6. **Grouped Inset Settings**: Align with macOS Sonoma/Sequoia System Settings standards with grouped inset rows and refined status indicators.

---

## 2. Design Philosophy & Aesthetic Principles

### 2.1 "Less is More, Data as Content" (Things 3 Inspiration)
- **No Card-in-Card Nesting**: The window canvas is a single, calm surface. Sections breathe through generous vertical spacing (32pt) rather than thick gray background boxes.
- **Subtle Separators**: Where visual boundaries are needed, use 0.5pt hairlines with low opacity (8–9%) rather than 1px solid dark/light strokes.
- **Typographic Hierarchy**: Size, weight, and opacity (Primary, Secondary, Tertiary) guide the eye without needing decorative containers or bright backgrounds.

### 2.2 Cohesive Light & Dark Adaptation
- **Light Mode**: Apple warm off-white canvas (`#F5F5F7`), pure white cards (`#FFFFFF`) where elevation is necessary, deep charcoal text (`#1D1D1F`), and muted warm gray hairlines.
- **Dark Mode**: Velvety graphite canvas (`#1C1C1E`—never harsh #000 OLED black), warm graphite surfaces (`#262629`), crisp off-white text (`#F5F5F7`), and luminous translucent accents.
- **Harmonious Saturation**: Avoid harsh neon hues. Use low-to-medium saturation colors that feel organic and restful during extended work sessions.

---

## 3. Architecture & Component Decomposition

### 3.1 Files Modified & Created
```
Sources/BennettUsageCore/
├── Views/
│   ├── ThemeColors.swift              // [NEW] Unified semantic design tokens (Canvas, Text, Border, Agent, Heatmap, Chart)
│   ├── ChartPalette.swift             // [MODIFIED] Powered by ThemeColors (14 curated agents + 16-color harmonic wheel)
│   ├── DashboardContentView.swift     // [REFACTORED] Things 3 single-canvas vertical layout, Hero ribbon, Proportional bars
│   ├── AgentFilterBarView.swift       // [REFACTORED] Featherlight dot + label pills with subtle tinted selection
│   ├── HeatmapGridView.swift          // [REFACTORED] 5-level organic green gradient, refined rounded cells
│   ├── MenuBarPopoverView.swift       // [REFACTORED] Cardless layout, mini segmented distribution bar, frosted material
│   ├── SettingsContentView.swift      // [REFACTORED] Grouped inset rows, refined icon badges, aligned controls
│   └── SettingsSheetView.swift        // [UPDATED] Clean sheet background styling
```

---

## 4. Unified Design Token Specification (`ThemeColors.swift`)

### 4.1 Canvas & Surfaces
| Token | Light Hex | Dark Hex | Usage |
|---|---|---|---|
| `AppTheme.Canvas.background` | `#F5F5F7` | `#1C1C1E` | Base window canvas background |
| `AppTheme.Surface.primary` | `#FFFFFF` | `#262629` | Primary container surface |
| `AppTheme.Surface.subtle` | `#EFEFF1` | `#2F2F34` | Inset well for grouped rows/stat pods |
| `AppTheme.Surface.hover` | `Black @ 4%` | `White @ 6%` | Interactive hover highlight |
| `AppTheme.Surface.selected` | `#0066CC @ 10%`| `#2997FF @ 16%`| Interactive selected pill / row background |
| `AppTheme.Surface.elevated` | `#FFFFFF` | `#2C2C30` | Tooltips, popovers, floating sheets |

### 4.2 Typography Hierarchy
| Token | Light Hex | Dark Hex | Role |
|---|---|---|---|
| `AppTheme.Text.primary` | `#1D1D1F` | `#F5F5F7` | Big KPI numbers, section titles, active labels |
| `AppTheme.Text.secondary` | `#6E6E73` | `#98989D` | Descriptions, period subtitles, compact units |
| `AppTheme.Text.tertiary` | `#86868B` | `#636366` | Table headers, chart axis ticks, ranks (`01`) |
| `AppTheme.Text.quaternary` | `#AEAEC2` | `#48484A` | Disabled states, subtle placeholders |

### 4.3 Hairlines & Borders
- `AppTheme.Border.divider`: `Black @ 8%` (Light) / `White @ 9%` (Dark), 0.5pt thickness.
- `AppTheme.Border.subtle`: `Black @ 6%` (Light) / `White @ 8%` (Dark), 0.5pt thickness.
- `AppTheme.Border.focus`: System accent `#0066CC` (Light) / `#2997FF` (Dark).

### 4.4 Curated 14 Agent Brand Palette
| Agent ID | Display Name | Light Hex | Dark Hex | Color Description |
|---|---|---|---|---|
| `claude` | Claude Code | `#CC5C36` | `#E07A5F` | Terracotta Sienna |
| `cursor` | Cursor | `#0284C7` | `#38BDF8` | Sky Cerulean |
| `codex` | OpenAI Codex | `#0D9468` | `#10B981` | OpenAI Emerald |
| `gemini` | Gemini CLI | `#4361EE` | `#6B8AFF` | Celestial Ultramarine |
| `copilot` | GitHub Copilot | `#6366F1` | `#818CF8` | Indigo Iris |
| `trae` | Trae | `#0891B2` | `#22D3EE` | Ocean Cyan Teal |
| `dsh` | DSH Harness | `#1D4ED8` | `#60A5FA` | Cobalt Sapphire |
| `pi` | Pi Agent | `#D97706` | `#FBBF24` | Amber Gold |
| `omp` | Oh My Pi | `#EA580C` | `#FB923C` | Sunset Tangerine |
| `cline` | Cline | `#0F766E` | `#2DD4BF` | Sea Pine Teal |
| `roo` | Roo Code · Cline | `#E11D48` | `#FB7185` | Rose Carmine |
| `qwen` | Qwen Code | `#7E22CE` | `#C084FC` | Royal Amethyst |
| `opencode` | OpenCode | `#475569` | `#94A3B8` | Slate Steel |
| `antigravity` | Antigravity | `#9333EA` | `#D8B4FE` | Cosmic Orchid |

### 4.5 Heatmap 5-Level Intensity Palette
- **Level 0 (Empty)**: Light `#E8E9ED`, Dark `#2C2C31` (recessed day dot)
- **Level 1 (Low)**: Light `#A7F3D0`, Dark `#114732` (sea-mint wash)
- **Level 2 (Medium)**: Light `#4ADE80`, Dark `#157F54` (leaf green)
- **Level 3 (High)**: Light `#16A34A`, Dark `#1EB878` (rich emerald)
- **Level 4 (Peak)**: Light `#15803D`, Dark `#34D399` (forest jewel / mint crystal)

---

## 5. Main Dashboard View Refactoring (`DashboardContentView.swift`)

### 5.1 Header Section
- **Range Switcher**: Borderless text pill picker. Selected item rendered with `AppTheme.Surface.primary` or subtle tint, `AppTheme.Text.primary` bold font. Inactive items rendered with `AppTheme.Text.secondary`.
- **Annual Dashboard Active Indicator**: When inspecting a full year, render a calm pill `2026 年度看板 ✕` with `AppTheme.Surface.selected` background and `AppTheme.Status.accent` text.
- **Settings Shortcut**: Monochromatic gear icon button with subtle hover background, right-aligned.

### 5.2 Agent Filter Bar (`AgentFilterBarView.swift`)
- Horizontal scrolling flow without borders.
- Each item: `Circle().frame(width: 6, height: 6).fill(color)` + `Text(name).font(.subheadline)`.
- Selected state: Soft pill background (`color.opacity(0.12)` or `AppTheme.Surface.selected`), medium weight. No stroke outlines.

### 5.3 Hero KPI & Sub-Metrics Ribbon
- **Top Row (Primary Total)**:
  - Left: Agent identity dot + agent name / "所有 Agent 用量", followed by the big token count: `font(.system(size: 32, weight: .semibold, design: .rounded))` in `AppTheme.Text.primary`. Beside it, a compact estimate `≈ 1.42M` in subtle pill.
  - Right: Spend formatted cleanly with `PricingEngine.shared.spendString(...)` in `font(.system(size: 28, weight: .semibold, design: .rounded))` and `AppTheme.Status.success`.
- **Bottom Row (Horizontal Metrics Ribbon)**:
  - Replaces the 5 mini boxed cards with a contiguous horizontal ribbon separated by 0.5pt hairlines (`AppTheme.Border.divider`):
    1. Input Tokens: Label + Compact Value (with full-token tooltip)
    2. Output Tokens: Label + Compact Value
    3. Cache Write: Label + Compact Value
    4. Cache Read: Label + Compact Value
    5. Cache Hit Rate: Percentage + 3pt micro `Capsule()` bar beneath.

### 5.4 Trend Chart (`TrendChartCard`)
- Chart title `font(.title3).fontWeight(.semibold)` + range subtitle `font(.caption).foregroundColor(AppTheme.Text.secondary)`.
- Segmented bar/line icon toggle.
- Line/Area mode: Swift Charts `AreaMark` with smooth vertical linear gradient (`AppTheme.Chart.primaryAreaGradient`) and `LineMark` with 2pt width.
- Bar mode: Bar marks with `cornerRadius: 3pt`.
- Light dashed gridlines (`AppTheme.Chart.gridline`, `lineWidth: 0.5, dash: [4, 4]`).
- Interactive hover: Vertical dashed indicator line + floating tooltip pill with `.ultraThinMaterial`, showing date, total, and top models.

### 5.5 Distribution Section: Proportional Segmented Bars
- **Replaces Donut Charts** with two clean cards: Tool Distribution and Model Distribution.
- **Component Layout**:
  - Title and range subtitle.
  - **Horizontal Segmented Distribution Bar**: A single 10pt-tall multi-colored continuous rounded capsule where each segment width equals `(tokens / totalTokens) * barWidth`.
  - **Contributor Ranking List**: Clean vertical list of Top 4–5 items:
    - 6pt color dot + Display Name
    - Percentage text (e.g. `48.2%`) in `AppTheme.Text.tertiary`
    - Token count (compact) + Spend in `AppTheme.Text.secondary`

### 5.6 Annual Panorama & Heatmap Section
- **Header**: Year title + clean year switcher pills (or dropdown menu if > 4 years) + display mode toggle (Calendar vs Monthly Trend).
- **Annual Key Metrics Strip**: 4-column summary (Total Tokens, Spend, Active Days, Top Agent) in a cardless row.
- **52-Week Grid**: 11×11pt cells with 2.5pt corner radius and 3pt spacing, filled with `AppTheme.Heatmap.color(for: intensity)`.
- **Day Focus Inspection**: When a cell is selected, display an inset cardless breakdown banner with active tools and clear button.

### 5.7 Top Projects Drilldown
- Clean ranking indices: `01`, `02`, `03` in `AppTheme.Text.tertiary` tabular digits (emojis 🥇🥈🥉 completely removed).
- Project name in `font(.subheadline).fontWeight(.medium)` with full directory path in tooltip.
- 3pt micro progress capsule indicating relative share against top project.
- Right-aligned compact tokens and spend.
- Clean text button for "Show More (N) / Show Less".

---

## 6. Menu Bar Popover Refactoring (`MenuBarPopoverView.swift`)

### 6.1 Layout & Visual Design
- **Backdrop**: macOS system frosted material (`.regularMaterial`).
- **Header**: App title + subtle action icons (Settings gear, Open Dashboard expand icon).
- **Today's Metric Row**:
  - Big Today Tokens (`font(.title2).bold()`) paired with Estimated Spend in `AppTheme.Status.success`.
- **Today's Tool Distribution**:
  - 4pt mini multi-segment horizontal distribution bar.
  - Below bar: 1-line or 2-column micro-list of active tools with color dots and token values.
- **Footer**:
  - "Sync Now" button in subtle tinted style, "Quit" button in secondary text style.
  - Remove gratuitous dividers, rely on 10–12pt natural vertical spacing.

---

## 7. Settings Sheet Refactoring (`SettingsContentView.swift`)

### 7.1 macOS Sonoma/Sequoia Grouped Inset Standards
- **Sidebar**:
  - Unified icon badges with soft background tints.
  - Native rounded selection highlights.
- **Grouped Form Rows**:
  - Each settings group is a single surface with `AppTheme.Surface.primary`, 10pt corner radius, and subtle 0.5pt hairline border.
  - Internal rows separated by 0.5pt inset hairlines (`AppTheme.Border.divider`).
  - Right-aligned toggles, popups, and inputs.
- **Agent Health Pane**:
  - 6pt status dots (Connected / Not Detected), clean path truncation, and subtle rescan button.
- **Pricing Pane**:
  - Clean currency selector (USD / CNY), exchange rate field, and structured pricing rules table.
- **Storage Pane**:
  - Record counts and database file size in clean typography, with vacuum/rebuild actions.
- **About Pane**:
  - Centered app icon with subtle drop shadow, version tag, and update status.

---

## 8. Verification & Testing Strategy

1. **Unit & Regression Tests**:
   - `swift test` must pass all existing test suites without regression (including `DashboardViewTests`, `MenuBarPopoverViewTests`, `SettingsSheetViewTests`, `HeatmapGridViewTests`, `MetricsAggregatorTests`).
2. **Theme Adaptability Testing**:
   - Verify that all dynamic colors resolve correctly under both Light and Dark macOS appearances.
   - Verify that `ChartPalette.shared.colors(for:)` produces stable, deterministic, non-clashing colors for any combination of agents/models.
3. **Localization Parity**:
   - Verify 100% localization parity across English and Simplified Chinese in all views.
4. **Visual & Interaction Verification**:
   - Run the app executable (`swift run BennettUsageApp`), verify window resizing, hover states, scrubber tooltips, filter bar interactions, and popover rendering.
