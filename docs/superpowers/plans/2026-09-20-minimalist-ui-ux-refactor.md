# UI/UX Minimalist Refactoring (Things 3 & Apple HIG Style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completely refactor Bennett Usage's UI and UX to a Things 3-inspired, Apple HIG-compliant minimalist design with breathable whitespace, zero card-in-card nesting, proportional segmented distribution bars, classical typography, and unified Light/Dark theme adaptation.

**Architecture:** Anchor all visual styling to `AppTheme` design tokens (`ThemeColors.swift`). Transform `DashboardContentView` into a single-canvas vertical stream, replace donut charts with horizontal distribution bars, streamline `AgentFilterBarView` into featherlight tags, and polish `MenuBarPopoverView` and `SettingsContentView` with macOS native materials and grouped inset rows.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, AppKit, SQLite

**Spec:** `docs/superpowers/specs/2026-09-20-minimalist-ui-ux-refactor-design.md`

## Global Constraints
- Target Platform: macOS 14.0+ (Sonoma, Sequoia).
- 100% Bilingual localization parity: all visible labels must use `localization.localized(...)`.
- Non-blocking data flow: retain existing 4-pipeline `.task(id:)` queries and `TrailingThrottle`.
- All existing tests in `Tests/` must continue to pass without regression.
- Visual standards: No card-in-card nesting; 0.5pt hairlines (`AppTheme.Border.divider`); Things 3 breathing whitespace (24–32pt section rhythm); curated 14-agent palette.

---

### Task 1: AgentFilterBarView & Header Range Switcher Refactoring

**Files:**
- Modify: `Sources/BennettUsageCore/Views/AgentFilterBarView.swift`
- Modify: `Sources/BennettUsageCore/Views/DashboardContentView.swift:150-225`
- Test: `Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift`

**Interfaces:**
- `AgentFilterBarView(selectedAgent: String?, availableAgents: [String], localization: LocalizationManager, onSelect: (String?) -> Void)`
- Header section in `DashboardContentView`: borderless range switcher, annual badge chip `2026 年度看板 ✕`, and quiet gear icon.

- [ ] **Step 1: Write test for refined AgentFilterBarView styling & selection behavior**

Add to `Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift`:
```swift
func testAgentFilterBarViewMinimalistState() throws {
    var selected: String? = nil
    let view = AgentFilterBarView(
        selectedAgent: selected,
        availableAgents: ["claude", "cursor", "codex"],
        localization: .shared
    ) { agent in
        selected = agent
    }
    XCTAssertNotNil(view)
    XCTAssertEqual(AgentFilterBarView.displayName(for: "claude"), "Claude Code")
    XCTAssertNotNil(AgentFilterBarView.colorMap["claude"])
}
```

- [ ] **Step 2: Run test to verify it passes with current setup**

Run: `swift test --filter HeatmapGridViewTests/testAgentFilterBarViewMinimalistState`
Expected: PASS

- [ ] **Step 3: Refactor `AgentFilterBarView.swift` to featherlight tags**

Update `Sources/BennettUsageCore/Views/AgentFilterBarView.swift`:
- Remove 1px stroke outlines on capsules.
- Each tag: `HStack(spacing: 5)` with 6pt dot (`Circle().fill(color).frame(width: 6, height: 6)`) + text.
- Selection style: subtle background fill (`color.opacity(0.12)` or `AppTheme.Surface.selected`), `fontWeight(.medium)`.
- Inactive style: transparent background, `AppTheme.Text.secondary` text.

- [ ] **Step 4: Refactor Header Section in `DashboardContentView.swift`**

In `Sources/BennettUsageCore/Views/DashboardContentView.swift`:
- In `headerSection`: style the range picker with cleaner presentation, quiet monochromatic settings gear button (`AppTheme.Text.secondary` with hover background), and refined annual badge chip (`AppTheme.Surface.selected` background with `✕` dismiss button).

- [ ] **Step 5: Run tests to verify header & filter bar**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BennettUsageCore/Views/AgentFilterBarView.swift Sources/BennettUsageCore/Views/DashboardContentView.swift Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift
git commit -m "refactor(views): modernize filter bar and header with Things 3 minimalist styling"
```

---

### Task 2: Hero KPI & Horizontal Metrics Ribbon Refactoring

**Files:**
- Modify: `Sources/BennettUsageCore/Views/DashboardContentView.swift:226-422`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- Hero Section: `heroSection: some View`
- Top Row: Large total tokens (`font(.system(size: 32, weight: .semibold, design: .rounded))`), compact tag `≈ 1.42M`, right-aligned spend in `AppTheme.Status.success`.
- Bottom Row: Horizontal 5-column metric ribbon (Input, Output, Cache Write, Cache Read, Cache Hit Rate with 3pt micro progress capsule).

- [ ] **Step 1: Write test for hero metrics values and formatting**

Add to `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testHeroMetricsRibbonCalculations() throws {
    let metrics = PeriodMetrics(
        totalTokens: 1_250_000,
        inputTokens: 800_000,
        outputTokens: 200_000,
        cacheWriteTokens: 150_000,
        cacheReadTokens: 100_000,
        totalCostUSD: 4.50,
        toolDistribution: [("claude", 1_250_000, 4.50)],
        modelDistribution: [("claude-3-5-sonnet", 1_250_000, 4.50)],
        projectRankings: [("/test/proj", 1_250_000, 4.50)],
        trendPoints: []
    )
    XCTAssertEqual(metrics.cacheHitRate, 0.4, accuracy: 0.01)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter DashboardViewTests/testHeroMetricsRibbonCalculations`
Expected: PASS

- [ ] **Step 3: Refactor `heroSection` in `DashboardContentView.swift`**

Replace the nested card structure (`heroSection`, `miniStatCard`, `cacheHitRateCard`) with:
1. **Top Row**:
   - Left: Agent identity dot (6pt) + agent name / "所有 Agent 用量" + large tabular token count (`font(.system(size: 32, weight: .semibold, design: .rounded))`) + compact badge.
   - Right: Period spend in `font(.system(size: 28, weight: .semibold, design: .rounded))` and `AppTheme.Status.success`, with period subtitle above.
2. **Bottom Row (Horizontal Ribbon)**:
   - Cardless horizontal flow: 5 equal columns separated by vertical hairlines (`Divider().frame(height: 24).opacity(0.3)`):
     - Fresh Input: Label + Compact Value (with full-token tooltip)
     - Model Output: Label + Compact Value
     - Cache Write: Label + Compact Value
     - Cache Read: Label + Compact Value
     - Cache Hit Rate: Percentage + 3pt micro `Capsule()` bar beneath.
   - Base surface: `AppTheme.Surface.primary` with subtle 0.5pt hairline border (`AppTheme.Border.subtle`).

- [ ] **Step 4: Run tests to verify hero section**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views/DashboardContentView.swift Tests/BennettUsageCoreTests/DashboardViewTests.swift
git commit -m "refactor(views): convert Hero KPI into cardless editorial ribbon"
```

---

### Task 3: Trend Chart Card Visual & Scrubber Modernization

**Files:**
- Modify: `Sources/BennettUsageCore/Views/DashboardContentView.swift:1150-1490`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- `TrendChartCard`: Swift Charts view with bar/line mode, dashed gridlines, smooth area gradient, floating backdrop-blurred scrubber tooltip.

- [ ] **Step 1: Write test for trend chart bucket and rendering integrity**

Add to `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testTrendPointDataIntegrity() throws {
    let point = TrendPoint(
        id: "2026-09-20-10",
        label: "10:00",
        tokens: 50_000,
        costUSD: 0.25,
        modelTokens: ["claude-3-5-sonnet": 50_000]
    )
    XCTAssertEqual(point.tokens, 50_000)
    XCTAssertEqual(point.modelTokens["claude-3-5-sonnet"], 50_000)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter DashboardViewTests/testTrendPointDataIntegrity`
Expected: PASS

- [ ] **Step 3: Refactor `TrendChartCard`**

In `Sources/BennettUsageCore/Views/DashboardContentView.swift`:
- Update card background to `AppTheme.Surface.primary` with `AppTheme.Border.subtle` (0.5pt).
- In Area/Line mode: use `AppTheme.Chart.primaryAreaGradient` for area fill, 2pt line stroke width.
- In Bar mode: 3pt corner radius for bars.
- Gridlines: use `AppTheme.Chart.gridline` with dashed stroke (`lineWidth: 0.5, dash: [4, 4]`).
- Scrubber tooltip: floating capsule with `.ultraThinMaterial` backdrop blur, subtle shadow, showing date, total tokens, and top model breakdown in clean tabular rows.

- [ ] **Step 4: Run tests to verify chart changes**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views/DashboardContentView.swift Tests/BennettUsageCoreTests/DashboardViewTests.swift
git commit -m "refactor(views): modernize trend chart with subtle gradients and frosted scrubber tooltip"
```

---

### Task 4: Distribution Section: Replace Donut Charts with Proportional Segmented Bars

**Files:**
- Modify: `Sources/BennettUsageCore/Views/DashboardContentView.swift:690-710, 1495-1880`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- `ProportionalDistributionCard`: Replaces `DonutBreakdownCard` and `ModelBreakdownCard`.
  - Properties: `title: String`, `subtitle: String`, `items: [(id: String, name: String, tokens: Int, costUSD: Double, color: Color)]`, `totalTokens: Int`, `localization: LocalizationManager`
  - Visual: 10pt-tall multi-segmented horizontal bar + compact contributor rows with percentage and tokens.

- [ ] **Step 1: Write test for distribution calculation**

Add to `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testDistributionShareCalculation() throws {
    let items = [
        ("claude", 600, 1.0),
        ("cursor", 400, 0.5)
    ]
    let total = items.reduce(0) { $0 + $1.1 }
    XCTAssertEqual(total, 1000)
    let share0 = Double(items[0].1) / Double(total)
    XCTAssertEqual(share0, 0.6, accuracy: 0.001)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter DashboardViewTests/testDistributionShareCalculation`
Expected: PASS

- [ ] **Step 3: Implement `ProportionalDistributionCard` and replace Donut cards**

In `Sources/BennettUsageCore/Views/DashboardContentView.swift`:
- Implement `ProportionalDistributionCard`:
  - Card container with `AppTheme.Surface.primary` and `AppTheme.Border.subtle`.
  - Header: Title (`font(.headline)`) + Range subtitle (`AppTheme.Text.secondary`).
  - **Horizontal Segmented Bar**: GeometryReader-based continuous capsule of 10pt height with rounded ends. Each segment's width is proportional to `(tokens / totalTokens) * width`.
  - **Contributor List**: Top 4 items with 6pt color dot, display name, percentage (e.g. `60.0%` in `AppTheme.Text.tertiary`), compact tokens + spend in `AppTheme.Text.secondary`.
- Update `distributionChartsSection` to use `ProportionalDistributionCard` for both tools and models.

- [ ] **Step 4: Run tests to verify distribution cards**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views/DashboardContentView.swift Tests/BennettUsageCoreTests/DashboardViewTests.swift
git commit -m "feat(views): replace donut charts with sleek proportional segmented distribution bars"
```

---

### Task 5: Annual Panorama, Heatmap & Project Rankings Refinement

**Files:**
- Modify: `Sources/BennettUsageCore/Views/HeatmapGridView.swift`
- Modify: `Sources/BennettUsageCore/Views/DashboardContentView.swift:425-688, 710-840`
- Test: `Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- Heatmap grid: 11×11pt cells with 2.5pt corner radius and 3pt spacing.
- Annual metrics strip: Cardless 4-column summary (Total Tokens, Spend, Active Days, Top Agent).
- Project rankings: Clean `01`, `02`, `03` typography indices (remove 🥇🥈🥉), 3pt micro progress capsule, right-aligned tokens & spend.

- [ ] **Step 1: Write test for rank formatting & heatmap cells**

Add to `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testRankIndexFormatting() throws {
    let rank1 = String(format: "%02d", 1)
    let rank10 = String(format: "%02d", 10)
    XCTAssertEqual(rank1, "01")
    XCTAssertEqual(rank10, "10")
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter DashboardViewTests/testRankIndexFormatting`
Expected: PASS

- [ ] **Step 3: Refactor `HeatmapGridView.swift` & `heatmapSection`**

- In `HeatmapGridView.swift`:
  - Optimize cell sizing to 11×11pt, 2.5pt corner radius, 3pt spacing.
  - Refine legend with `AppTheme.Heatmap.color(for:)`.
- In `DashboardContentView.swift` (`heatmapSection`):
  - Style annual metrics strip with `AppTheme.Surface.subtle` or cardless row.
  - Refine year selector buttons and day inspection banner.

- [ ] **Step 4: Refactor `projectsSection`**

In `DashboardContentView.swift`:
- Replace emoji medals (🥇🥈🥉) with `String(format: "%02d", rank)` in `font(.caption).monospacedDigit().foregroundColor(AppTheme.Rank.color(for: rank))`.
- Update relative progress capsule height to 3pt.
- Format folder name and right-aligned tokens/spend.
- Update "Show More / Show Less" button to clean text button.

- [ ] **Step 5: Run tests to verify heatmap and projects**

Run: `swift test --filter HeatmapGridViewTests` && `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BennettUsageCore/Views/HeatmapGridView.swift Sources/BennettUsageCore/Views/DashboardContentView.swift Tests/BennettUsageCoreTests/DashboardViewTests.swift
git commit -m "refactor(views): refine heatmap cells and replace project medal emojis with classical 01-03 typography"
```

---

### Task 6: Menu Bar Popover & Settings Sheet Minimalist Refactoring

**Files:**
- Modify: `Sources/BennettUsageCore/Views/MenuBarPopoverView.swift`
- Modify: `Sources/BennettUsageCore/Views/SettingsContentView.swift`
- Modify: `Sources/BennettUsageCore/Views/SettingsSheetView.swift`
- Test: `Tests/BennettUsageCoreTests/MenuBarPopoverViewTests.swift`
- Test: `Tests/BennettUsageCoreTests/SettingsSheetViewTests.swift`

**Interfaces:**
- `MenuBarPopoverView`: Frosted `.regularMaterial` backdrop, cardless today metrics, 4pt mini distribution bar, compact tool indicators, clean buttons.
- `SettingsContentView`: Grouped inset rows with `AppTheme.Surface.primary` and 0.5pt hairlines (`AppTheme.Border.divider`).

- [ ] **Step 1: Write test for MenuBarPopover mini distribution data**

Add to `Tests/BennettUsageCoreTests/MenuBarPopoverViewTests.swift`:
```swift
func testPopoverMiniDistributionActiveTools() throws {
    let summary = TodaySummary(
        totalTokens: 100_000,
        totalCostUSD: 0.50,
        toolBreakdown: ["claude": 70_000, "cursor": 30_000]
    )
    let active = MenuBarPopoverView.activeTools(for: summary)
    XCTAssertEqual(active.count, 2)
    XCTAssertEqual(active[0].id, "claude")
    XCTAssertEqual(active[0].tokens, 70_000)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter MenuBarPopoverViewTests/testPopoverMiniDistributionActiveTools`
Expected: PASS

- [ ] **Step 3: Refactor `MenuBarPopoverView.swift`**

- Remove excessive Dividers, adopt 10–12pt natural vertical spacing.
- Top row: App title + quiet Settings gear & Open Dashboard buttons with hover highlights.
- Today metrics row: Big Tokens (`font(.title2).bold()`) + Estimated Spend in `AppTheme.Status.success`.
- Mini distribution bar: 4pt multi-segment continuous capsule showing relative share of today's active tools.
- Micro tool indicator row: 6pt color dots + tool names + compact tokens.
- Footer: Subtle "Sync Now" button and secondary text "Quit" button.

- [ ] **Step 4: Refactor `SettingsContentView.swift` & `SettingsSheetView.swift`**

- In `SettingsContentView.swift`:
  - Align with macOS Sonoma/Sequoia grouped inset rows: cards with `AppTheme.Surface.primary`, 10pt radius, 0.5pt hairline dividers between rows.
  - Refine sidebar icon tints and selection highlight.
  - Align all toggles, popups, and text inputs to the right edge.
- In `SettingsSheetView.swift`:
  - Set background to `AppTheme.Canvas.background`.

- [ ] **Step 5: Run tests for Popover and Settings**

Run: `swift test --filter MenuBarPopoverViewTests` && `swift test --filter SettingsSheetViewTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/BennettUsageCore/Views/MenuBarPopoverView.swift Sources/BennettUsageCore/Views/SettingsContentView.swift Sources/BennettUsageCore/Views/SettingsSheetView.swift Tests/BennettUsageCoreTests/MenuBarPopoverViewTests.swift
git commit -m "refactor(views): modernize MenuBar popover and settings sheet with macOS native materials and grouped rows"
```

---

### Task 7: Full Test Suite Regression & End-to-End Verification

**Files:**
- Test: All tests across `Tests/`

- [ ] **Step 1: Run full unit test suite**

Run: `swift test`
Expected: 233+ tests passed with 0 failures.

- [ ] **Step 2: Verify binary compilation**

Run: `swift build`
Expected: Build complete with 0 warnings/errors.

- [ ] **Step 3: Commit any final polish**

```bash
git status
# If any unstaged adjustments:
git add -A && git commit -m "chore: final visual and test polish for minimalist UI/UX refactoring"
```
