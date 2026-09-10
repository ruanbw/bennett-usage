# Dashboard & Settings UI/UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Dashboard and Settings UI/UX into a modern native macOS `NavigationSplitView` architecture with interactive Agent capsule filtering, Hero KPI cards, interactive Heatmap day-focusing, Top projects ranking badges, and a comprehensive macOS System Settings-style configuration center.

**Architecture:** Split the UI into a native macOS `NavigationSplitView` with a left `SidebarView` (navigation, agent health badge, rescan trigger) and a detail view switching between `DashboardContentView` and `SettingsContentView`. Extend `MetricsAggregator` with optional `toolFilter`, make `PricingEngine` dynamic and persisted, and provide 100% bilingual localization parity across all new views.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, SQLite (WAL mode), AppKit integration.

**Spec:** `docs/superpowers/specs/2026-09-11-dashboard-settings-redesign-design.md`

## Global Constraints
- Target Platform: macOS 14.0+
- Minimum window dimensions: minWidth 960, minHeight 660 (ideal 1060 × 720)
- Zero third-party dependencies outside Swift standard library and Apple frameworks
- 100% localization parity between English (`en`) and Simplified Chinese (`zh-Hans`)
- Agent brand colors: Pi (`#10B981`), Omp (`#F59E0B`), Claude (`#EA580C`), Codex (`#0EA5E9`)
- Number formatting: SF Pro Rounded with `.monospacedDigit()`, compact token notation (K/M/B) with full-value tooltips
- Strict test-driven verification: all tests must pass via `swift test`

---

### Task 1: Localization Expansion & Dynamic Pricing Engine

**Files:**
- Modify: `Sources/BennettUsageCore/Localization/LocalizationKey.swift`
- Modify: `Sources/BennettUsageCore/Localization/LocalizationManager.swift`
- Modify: `Sources/BennettUsageCore/Pricing/PricingEngine.swift`
- Test: `Tests/BennettUsageCoreTests/LocalizationTests.swift`
- Test: `Tests/BennettUsageCoreTests/PricingEngineTests.swift`

**Interfaces:**
- Consumes: Existing `LocalizationKey` enum and `PricingEngine` singleton
- Produces:
  - New `LocalizationKey` cases: `navDashboard`, `navSettings`, `agentsConnected`, `rescanNow`, `syncedJustNow`, `syncedMinutesAgo`, `filterAllAgents`, `clearFocus`, `agentHealthSection`, `pricingSection`, `storageSection`, `exchangeRateLabel`, `preferredCurrencyLabel`, `revealInFinder`, `rebuildRollups`, `clearAllRecords`, `clearRecordsConfirmTitle`, `clearRecordsConfirmMessage`, `autoRefreshLabel`, `autoRefreshOff`, `autoRefreshSeconds`, `storageStatus`, `generalSettings`, `usdOption`, `cnyOption`.
  - `PricingEngine.shared.usdToCnyRate: Double` (reads/writes `UserDefaults`)
  - `PricingEngine.shared.setExchangeRate(_ rate: Double)`
  - `PricingEngine.shared.preferredCurrency: PreferredCurrency` (`.usd` | `.cny`)
  - `PricingEngine.shared.setPreferredCurrency(_ currency: PreferredCurrency)`
  - `PricingEngine.shared.spendString(_ costUSD: Double) -> String` (formats `$X.XX (¥X.XX)` or `¥X.XX ($X.XX)`)

- [ ] **Step 1: Write the failing tests for localization and pricing engine**

In `Tests/BennettUsageCoreTests/PricingEngineTests.swift`:
```swift
func testDynamicExchangeRateAndPreferredCurrency() {
    let engine = PricingEngine.shared
    engine.setExchangeRate(7.50)
    XCTAssertEqual(engine.usdToCnyRate, 7.50)

    engine.setPreferredCurrency(.cny)
    let spendCnyFirst = engine.spendString(1.0)
    XCTAssertTrue(spendCnyFirst.hasPrefix("¥7.50"), "Expected CNY first, got: \(spendCnyFirst)")

    engine.setPreferredCurrency(.usd)
    let spendUsdFirst = engine.spendString(1.0)
    XCTAssertTrue(spendUsdFirst.hasPrefix("$1.00"), "Expected USD first, got: \(spendUsdFirst)")
}
```

In `Tests/BennettUsageCoreTests/LocalizationTests.swift`:
```swift
func testNewNavigationAndSettingsLocalizationKeysExist() {
    let keys: [LocalizationKey] = [
        .navDashboard, .navSettings, .agentsConnected, .rescanNow,
        .filterAllAgents, .clearFocus, .agentHealthSection,
        .pricingSection, .storageSection, .exchangeRateLabel,
        .revealInFinder, .rebuildRollups, .clearAllRecords
    ]
    for key in keys {
        let en = LocalizationManager.shared.localized(key, language: .english)
        let zh = LocalizationManager.shared.localized(key, language: .simplifiedChinese)
        XCTAssertFalse(en.isEmpty, "Missing English translation for \(key)")
        XCTAssertFalse(zh.isEmpty, "Missing Chinese translation for \(key)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PricingEngineTests`
Expected: FAIL due to missing `setExchangeRate` / `preferredCurrency`

- [ ] **Step 3: Implement Localization keys & Dynamic PricingEngine**

1. Add cases to `LocalizationKey.swift` and translations in `LocalizationManager.swift`.
2. In `PricingEngine.swift`:
   - Define `public enum PreferredCurrency: String, Sendable, CaseIterable { case usd, cny }`
   - Store and retrieve `usdToCnyRate` and `preferredCurrency` via `UserDefaults.standard`.
   - Update `spendString(_ costUSD: Double) -> String`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PricingEngineTests` and `swift test --filter LocalizationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Localization Sources/BennettUsageCore/Pricing Tests/BennettUsageCoreTests
git commit -m "feat(pricing): add dynamic exchange rate, currency preferences, and expanded i18n keys"
```

---

### Task 2: MetricsAggregator Tool/Agent Filtering Extension

**Files:**
- Modify: `Sources/BennettUsageCore/Analytics/MetricsAggregator.swift`
- Test: `Tests/BennettUsageCoreTests/MetricsAggregatorTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager`, `UnifiedTokenRecord`, `TimeRangeOption`
- Produces:
  - `AgentHealthInfo: Identifiable, Sendable` struct (`id`, `displayName`, `defaultPath`, `isInstalled`, `recordCount`, `lastRecordTimestamp`)
  - `fetchPeriodMetrics(range: TimeRangeOption, toolFilter: String? = nil) async throws -> PeriodMetrics`
  - `fetchHeatmap(range: TimeRangeOption, toolFilter: String? = nil) async throws -> [HeatmapDayCell]`
  - `fetchAgentHealthInfos() async throws -> [AgentHealthInfo]`

- [ ] **Step 1: Write failing tests for toolFilter and agent health infos**

In `Tests/BennettUsageCoreTests/MetricsAggregatorTests.swift`:
```swift
func testFetchPeriodMetricsWithToolFilter() async throws {
    let dbManager = try DatabaseManager(inMemory: true)
    let aggregator = MetricsAggregator(databaseManager: dbManager)

    // Insert 1 claude record and 1 pi record
    let now = Date()
    let dayKey = "2026-09-11"
    let r1 = UnifiedTokenRecord(
        id: "claude_1", sourceId: "claude", timestamp: now, dayKey: dayKey,
        sessionKey: "s1", projectFolder: "/p1", model: "claude-3-5-sonnet",
        inputTokens: 100, outputTokens: 50, totalTokens: 150,
        costUSD: 0.01, metadata: nil
    )
    let r2 = UnifiedTokenRecord(
        id: "pi_1", sourceId: "pi", timestamp: now, dayKey: dayKey,
        sessionKey: "s2", projectFolder: "/p2", model: "deepseek-coder",
        inputTokens: 200, outputTokens: 100, totalTokens: 300,
        costUSD: 0.02, metadata: nil
    )
    try await dbManager.insertUnifiedTokenRecords([r1, r2])

    let claudeMetrics = try await aggregator.fetchPeriodMetrics(range: .last30Days, toolFilter: "claude")
    XCTAssertEqual(claudeMetrics.totalTokens, 150)
    XCTAssertEqual(claudeMetrics.projectRankings.count, 1)
    XCTAssertEqual(claudeMetrics.projectRankings.first?.project, "/p1")

    let allMetrics = try await aggregator.fetchPeriodMetrics(range: .last30Days, toolFilter: nil)
    XCTAssertEqual(allMetrics.totalTokens, 450)
    XCTAssertEqual(allMetrics.projectRankings.count, 2)
}

func testFetchAgentHealthInfos() async throws {
    let dbManager = try DatabaseManager(inMemory: true)
    let aggregator = MetricsAggregator(databaseManager: dbManager)
    let healthInfos = try await aggregator.fetchAgentHealthInfos()
    XCTAssertEqual(healthInfos.count, 4)
    let ids = Set(healthInfos.map(\.id))
    XCTAssertTrue(ids.contains("pi"))
    XCTAssertTrue(ids.contains("omp"))
    XCTAssertTrue(ids.contains("claude"))
    XCTAssertTrue(ids.contains("codex"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testFetchPeriodMetricsWithToolFilter`
Expected: FAIL with "extra argument 'toolFilter' in call"

- [ ] **Step 3: Implement toolFilter and fetchAgentHealthInfos in MetricsAggregator**

1. Define `public struct AgentHealthInfo: Identifiable, Sendable`.
2. Update `fetchPeriodMetrics` to apply SQL filter:
   `if let toolFilter = toolFilter, !toolFilter.isEmpty { whereClauses.append("LOWER(source_id) = '\(toolFilter.lowercased())'") }`
3. Update `fetchHeatmap` similarly.
4. Implement `fetchAgentHealthInfos()` querying `AdapterRegistry.shared.allAdapters()` and checking `FileManager.default.fileExists(atPath:)` and querying `unified_token_records` counts.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MetricsAggregatorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Analytics Tests/BennettUsageCoreTests
git commit -m "feat(analytics): add toolFilter support and agent health diagnostics to MetricsAggregator"
```

---

### Task 3: Full-Featured Settings Center (`SettingsContentView` & `SettingsSheetView`)

**Files:**
- Create: `Sources/BennettUsageCore/Views/SettingsContentView.swift`
- Modify: `Sources/BennettUsageCore/Views/SettingsSheetView.swift`
- Test: `Tests/BennettUsageCoreTests/SettingsSheetViewTests.swift`

**Interfaces:**
- Consumes: `LocalizationManager`, `MetricsAggregator`, `PricingEngine`, `AgentHealthInfo`
- Produces:
  - `SettingsContentView`: Grouped inset card-based settings view featuring:
    1. General (Language picker, Auto-refresh picker: Off/10s/30s/60s)
    2. Agent Health & Detection (Pi, Omp, Claude, Codex paths, status dot, records count, "Rescan Now" button)
    3. Pricing & Currency (USD/CNY rate input field, Preferred currency radio/segmented picker)
    4. Storage & Maintenance (DB path, DB file size in MB, record count, "Reveal in Finder", "Rebuild Aggregates", "Clear All Records" with confirmation alert)
    5. About (App icon, version, open source links, local-first privacy statement)
  - `SettingsSheetView`: Wraps `SettingsContentView` with a standard header and dismiss button for sheet presentation.

- [ ] **Step 1: Write failing tests for SettingsContentView and SettingsSheetView**

In `Tests/BennettUsageCoreTests/SettingsSheetViewTests.swift`:
```swift
func testSettingsContentViewInitializationAndSections() async throws {
    let dbManager = try DatabaseManager(inMemory: true)
    let aggregator = MetricsAggregator(databaseManager: dbManager)
    let view = SettingsContentView(aggregator: aggregator, localization: .shared)
    XCTAssertNotNil(view)
}

func testSettingsSheetViewWrapsContent() {
    var dismissed = false
    let view = SettingsSheetView(localization: .shared) {
        dismissed = true
    }
    XCTAssertNotNil(view)
    view.onDismiss()
    XCTAssertTrue(dismissed)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsSheetViewTests`
Expected: FAIL with "cannot find 'SettingsContentView' in scope"

- [ ] **Step 3: Implement SettingsContentView and update SettingsSheetView**

1. Create `Sources/BennettUsageCore/Views/SettingsContentView.swift`:
   - Implement grouped inset cards using `VStack`, `HStack`, `Form` / custom card containers with `cornerRadius: 10`, subtle border.
   - Wire language binding to `localization.selectedLanguage`.
   - Wire exchange rate to `PricingEngine.shared.setExchangeRate`.
   - Wire currency preference to `PricingEngine.shared.setPreferredCurrency`.
   - Load `agentHealthInfos` asynchronously via `aggregator.fetchAgentHealthInfos()`.
   - Implement "Reveal in Finder" using `NSWorkspace.shared.activateFileViewerSelecting([dbURL])`.
   - Implement "Rebuild Aggregates" calling `aggregator.rebuildRollups()` / recalculating.
   - Implement "Clear All Records" with `.alert` confirmation.
2. In `SettingsSheetView.swift`, refactor `body` to display `SettingsContentView(aggregator: aggregator, localization: localization, onDismiss: onDismiss)` with comfortable sheet frame (`width: 600, height: 500`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsSheetViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views Tests/BennettUsageCoreTests
git commit -m "feat(settings): create modern macOS SettingsContentView and modernize SettingsSheetView"
```

---

### Task 4: Interactive Heatmap Focus & Agent Capsule Filtering Components

**Files:**
- Modify: `Sources/BennettUsageCore/Views/HeatmapGridView.swift`
- Create: `Sources/BennettUsageCore/Views/AgentFilterBarView.swift`
- Test: `Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift`

**Interfaces:**
- Consumes: `LocalizationManager`, `HeatmapDayCell`
- Produces:
  - `AgentFilterBarView`: Horizontal capsule pills for `All` + `Pi Agent` + `Oh My Pi` + `Claude Code` + `OpenAI Codex` with brand color badges and active state highlight.
  - `HeatmapGridView`: Enhanced with `selectedDayKey: String?` binding to render active focus ring around the clicked day, and trigger `onSelectDay: ((HeatmapDayCell) -> Void)?`.

- [ ] **Step 1: Write failing tests for AgentFilterBarView and HeatmapGridView selection**

In `Tests/BennettUsageCoreTests/HeatmapGridViewTests.swift`:
```swift
func testAgentFilterBarViewOptions() {
    var selected: String? = nil
    let filterBar = AgentFilterBarView(
        selectedAgent: selected,
        availableAgents: ["claude", "codex", "pi", "omp"],
        localization: .shared
    ) { newSelection in
        selected = newSelection
    }
    XCTAssertNotNil(filterBar)
}

func testHeatmapGridSelectionHighlight() {
    let cell = HeatmapDayCell(date: Date(), dayKey: "2026-09-11", totalTokens: 1000, costUSD: 0.05, intensity: 2)
    let grid = HeatmapGridView(cells: [cell], selectedDayKey: "2026-09-11", localization: .shared) { _ in }
    XCTAssertNotNil(grid)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HeatmapGridViewTests`
Expected: FAIL with "cannot find 'AgentFilterBarView' in scope"

- [ ] **Step 3: Implement AgentFilterBarView & HeatmapGridView day selection**

1. Create `Sources/BennettUsageCore/Views/AgentFilterBarView.swift`:
   - Capsules: "All Agents" + each agent with its branded dot/icon.
   - Smooth animated selection capsule background.
2. In `Sources/BennettUsageCore/Views/HeatmapGridView.swift`:
   - Add `public var selectedDayKey: String? = nil` parameter to `init`.
   - When a cell matches `selectedDayKey`, draw a 1.5pt accent stroke ring around it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HeatmapGridViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views Tests/BennettUsageCoreTests
git commit -m "feat(views): add AgentFilterBarView and HeatmapGridView day selection highlight"
```

---

### Task 5: Refactored Dashboard Content (`DashboardContentView`)

**Files:**
- Create: `Sources/BennettUsageCore/Views/DashboardContentView.swift`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- Consumes: `MetricsAggregator`, `LocalizationManager`, `AgentFilterBarView`, `HeatmapGridView`, `TokenFormatter`, `PricingEngine`
- Produces:
  - `DashboardContentView: View`:
    - Top header: Title + TimeRange segmented picker (Today, 24h, 7d, 30d, 1y, Year menu).
    - Agent capsule filter pill bar.
    - 4 Hero KPI cards (Period Tokens, Today's Tokens, Estimated Spend with $/¥ dual currency, Most Active Agent) with colored icon container backgrounds.
    - Contribution Heatmap with day inspection banner: displays date, formatted tokens, cost, agent breakdown pills, and a `[Clear Focus ✕]` button.
    - Dual Analytics Charts (SectorMark tool share donut chart + BarMark trend chart).
    - Top Projects Ranking list with #1 Gold, #2 Silver, #3 Bronze badges, progress bars, and cost.

- [ ] **Step 1: Write failing tests for DashboardContentView**

In `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testDashboardContentViewInitialization() async throws {
    let dbManager = try DatabaseManager(inMemory: true)
    let aggregator = MetricsAggregator(databaseManager: dbManager)
    let contentView = DashboardContentView(aggregator: aggregator, localization: .shared)
    XCTAssertNotNil(contentView)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testDashboardContentViewInitialization`
Expected: FAIL with "cannot find 'DashboardContentView' in scope"

- [ ] **Step 3: Implement DashboardContentView**

Create `Sources/BennettUsageCore/Views/DashboardContentView.swift`:
- State variables:
  - `@State private var selectedRange: TimeRangeOption = .last30Days`
  - `@State private var selectedToolFilter: String? = nil`
  - `@State private var selectedCell: HeatmapDayCell? = nil`
  - `@State private var periodMetrics: PeriodMetrics?`
  - `@State private var todaySummary: TodaySummary?`
  - `@State private var heatmapCells: [HeatmapDayCell] = []`
  - `@State private var availableYears: [Int] = []`
- `loadData()` function: fetches data using `selectedRange` and `selectedToolFilter`.
- Refactor KPI cards, Heatmap inspection banner, Swift Charts, and Top Projects with medal badges.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views Tests/BennettUsageCoreTests
git commit -m "feat(views): implement comprehensive DashboardContentView with dual filtering and KPI hero cards"
```

---

### Task 6: Sidebar Navigation & Split View Container (`SidebarView` & `DashboardView`)

**Files:**
- Create: `Sources/BennettUsageCore/Views/SidebarView.swift`
- Modify: `Sources/BennettUsageCore/Views/DashboardView.swift`
- Modify: `Sources/BennettUsageApp/DashboardWindowManager.swift`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`

**Interfaces:**
- Consumes: `DashboardContentView`, `SettingsContentView`, `LocalizationManager`, `MetricsAggregator`, `SyncCoordinator`
- Produces:
  - `public enum NavigationItem: String, CaseIterable, Identifiable, Hashable { case dashboard, settings }`
  - `SidebarView: View`:
    - Brand header (`Bennett Usage` + subtitle)
    - List of `NavigationItem` (`.dashboard` and `.settings`)
    - Sticky bottom health status card (e.g. `🟢 4 Agents Connected`, `Synced just now`, `Rescan Now` button with spin animation)
  - `DashboardView: View`:
    - Root `NavigationSplitView` hosting `SidebarView` and switching detail view.
    - Backward-compatible `init(aggregator:localization:showSettingsInitially:)`.
    - Minimum window frame `minWidth: 980, minHeight: 680`.

- [ ] **Step 1: Write failing tests for SidebarView and DashboardView NavigationSplitView**

In `Tests/BennettUsageCoreTests/DashboardViewTests.swift`:
```swift
func testDashboardViewNavigationItems() async throws {
    let dbManager = try DatabaseManager(inMemory: true)
    let aggregator = MetricsAggregator(databaseManager: dbManager)

    let defaultView = DashboardView(aggregator: aggregator, localization: .shared, showSettingsInitially: false)
    XCTAssertNotNil(defaultView)

    let settingsView = DashboardView(aggregator: aggregator, localization: .shared, showSettingsInitially: true)
    XCTAssertNotNil(settingsView)
}
```

- [ ] **Step 2: Run test to verify it fails if interfaces mismatch**

Run: `swift test --filter DashboardViewTests`
Expected: Baseline check

- [ ] **Step 3: Implement SidebarView and refactor DashboardView to NavigationSplitView**

1. Create `Sources/BennettUsageCore/Views/SidebarView.swift`:
   - Bind to `@Binding var selectedItem: NavigationItem`.
   - Render brand icon + label, navigation items, and bottom status badge with "Rescan Now" button triggering `Task { await onSyncNow() }`.
2. In `Sources/BennettUsageCore/Views/DashboardView.swift`:
   - Replace old monolithic body with `NavigationSplitView`:
     ```swift
     NavigationSplitView {
         SidebarView(
             selectedItem: $selectedItem,
             agentHealthInfos: agentHealthInfos,
             isSyncing: isSyncing,
             lastSyncDate: lastSyncDate,
             onSyncNow: { await performSync() },
             localization: localization
         )
         .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
     } detail: {
         switch selectedItem {
         case .dashboard:
             DashboardContentView(aggregator: aggregator, localization: localization)
         case .settings:
             SettingsContentView(aggregator: aggregator, localization: localization)
         }
     }
     .frame(minWidth: 980, minHeight: 680)
     ```
3. Update `DashboardWindowManager.swift` default size to `1060 × 720` for generous breathability.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DashboardViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Views Sources/BennettUsageApp Tests/BennettUsageCoreTests
git commit -m "feat(views): integrate NavigationSplitView with SidebarView and detail views"
```

---

### Task 7: End-to-End Integration Verification & Smoke Testing

**Files:**
- Test: `Tests/BennettUsageCoreTests/EndToEndSmokeTests.swift`
- Test: `Tests/BennettUsageCoreTests/DashboardViewTests.swift`
- Test: `Tests/BennettUsageCoreTests/SettingsSheetViewTests.swift`

**Interfaces:**
- Consumes: Complete project workspace
- Produces: All test suites green, zero compiler warnings, zero broken contracts.

- [ ] **Step 1: Run complete test suite**

Run: `swift test`
Expected: All tests pass (including EndToEndSmokeTests and newly added view/aggregator/pricing tests).

- [ ] **Step 2: Verify binary compilation**

Run: `swift build`
Expected: SUCCESS

- [ ] **Step 3: Commit any test adjustments or final cleanup**

```bash
git add Tests/
git commit -m "test: verify end-to-end integration and navigation flows"
```
