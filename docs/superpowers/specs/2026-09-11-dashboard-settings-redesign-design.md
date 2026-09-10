# Dashboard & Settings UI/UX Redesign Specification

- **Date**: 2026-09-11
- **Target Platform**: macOS 14.0+ (Sonoma, Sequoia)
- **Tech Stack**: Swift 6, SwiftUI, Swift Charts, SQLite (WAL mode)
- **Repository**: `bennett-usage`
- **Application Type**: Native macOS Menu Bar Item + Standalone SplitView Dashboard Window
- **Design References**: `cc-switch` (desktop AI manager layout & settings architecture) and `juejin-usage` (Token tracker analytics, capsule filtering & ranking)

---

## 1. Executive Summary & Goals

### 1.1 Overview
This technical specification details the complete visual and architectural redesign of the **Dashboard** and **Settings** experiences within `bennett-usage`. The redesign transitions the app from a single-page vertical card stack to a professional, native macOS desktop tool featuring a **NavigationSplitView** sidebar structure, interactive **Agent capsule filter pills**, enhanced **Hero KPI metric cards**, **interactive Heatmap day-focusing**, and an exhaustive **macOS System Settings-style configuration center**.

### 1.2 Key Objectives
1. **Desktop-Class Navigation (`NavigationSplitView`)**: Adopt macOS native sidebar navigation with items for **用量看板 (Dashboard)** and **系统设置 (Settings)**, along with a persistent footer displaying agent connectivity status and manual one-click rescan.
2. **Multi-Dimensional Filtering (Time Range + Agent Capsules)**: Integrate dual-axis filtering directly inspired by `juejin-usage` and `cc-switch`, allowing users to switch time spans (Today, 24h, 7d, 30d, 1y, Year) and filter the entire dashboard by specific agent (`All`, `Pi Agent`, `Oh My Pi`, `Claude Code`, `OpenAI Codex`).
3. **Refined Analytics & Hero KPI Cards**:
   - 4 Hero KPI cards with colored glyph containers, dual-currency spend ($USD and ¥CNY), compact token formatting with full-value tooltips.
   - Interactive GitHub contribution heatmap with single-day inspection banner and focus clearing.
   - Donut tool-share distribution and gradient trend charts.
   - Top projects ranking with Gold/Silver/Bronze rank badges and relative progress bars.
4. **Full-Featured Settings Center (`SettingsContentView`)**:
   - **General**: Multi-language picker (System Default, 中文, English), auto-refresh frequency.
   - **Agent Health & Diagnostics**: Auto-detect directory paths (`~/.pi`, `~/.omp`, `~/.claude`, `~/.codex`), record counts, connection indicators, and a "Rescan & Sync Now" action.
   - **Pricing & Currency**: Configurable USD/CNY exchange rate (persisted in `UserDefaults`) and preferred currency display toggle.
   - **Storage & Maintenance**: SQLite database size and record counts, "Reveal in Finder", "Rebuild Aggregates", and safe "Clear All Records" with confirmation dialog.
   - **About**: Version, architecture highlights, privacy guarantee (100% local, no prompt/code collection), and GitHub repository links.
5. **100% Localization Parity**: Complete English and Simplified Chinese coverage across all new UI components and settings keys.

---

## 2. Architecture & Component Decomposition

### 2.1 Component Structure
```
Sources/BennettUsageCore/
├── Views/
│   ├── DashboardView.swift          // Top-level NavigationSplitView coordinating sidebar & detail
│   ├── SidebarView.swift            // Sidebar navigation with agent health indicator & sync trigger
│   ├── DashboardContentView.swift   // Core analytics view: Filters, KPIs, Heatmap, Charts, Ranking
│   ├── SettingsContentView.swift    // Grouped inset cards: General, Agents, Pricing, Storage, About
│   ├── SettingsSheetView.swift      // Backward-compatible modal wrapper around SettingsContentView
│   ├── HeatmapGridView.swift        // 52-week activity calendar with click-to-focus support
│   └── MenuBarPopoverView.swift     // Menu bar popover with shortcuts to Dashboard and Settings
├── Analytics/
│   ├── MetricsAggregator.swift      // Extended to support optional `toolFilter: String?`
│   └── TokenFormatter.swift         // Unified compact formatting, exact tooltips, and currency strings
├── Pricing/
│   └── PricingEngine.swift          // Dynamic USD/CNY rate from UserDefaults, preferred currency helpers
└── Localization/
    ├── LocalizationKey.swift        // Comprehensive localization enum keys
    └── LocalizationManager.swift    // ObservableObject driving instant language switching
```

### 2.2 Wireframe & Layout Specifications

#### Dashboard Split View Layout
```
+-------------------------------------------------------------------------------------------------+
|  ⚪ 🟡 🟢   [Bennett Usage]                                                                     |
+-------------------+-----------------------------------------------------------------------------+
| 🧭 侧边栏 (210px)  | 📱 仪表盘主内容区 (DashboardContentView)                                    |
|                   | 📊 用量看板                                   [ 24h | 今天 | 7天 | 30天* | 1年 ▾ ]|
| [⚡ Bennett]      | 筛选: [ 全部* ] [ 🟢 Pi ] [ 🟡 Omp ] [ 🟠 Claude ] [ 🔵 Codex ]                |
| AI Agent Tracker  |                                                                             |
|                   | [🔥 周期总 Token]  [⚡ 今日 Token]   [💰 预估总支出]    [✨ 活跃主力 Agent]   |
| ── 导航 ──        |   14.2M            382.5K          $4.82 / ¥35.19     Claude Code       |
| 📊 用量看板       |   近30天累计        今日消耗量       按模型标准费率     占比 58.4% (8.3M) |
| ⚙️ 系统设置       |                                                                             |
|                   | 📅 Token 活动热力图                                     30 天中 18 个活跃天 |
|                   | 🟩🟩⬜🟩🟩🟩⬜🟩🟩🟩🟩🟩⬜⬜🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩⬜🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 |
|                   | 📌 2026-09-10 (周四): 1.24M tokens ($0.412) · [🟠 Claude: 800K] [🟢 Pi: 440K] [✕] |
|                   |                                                                             |
|                   | [ 🍩 Agent 份额占比 ]               | [ 📊 消耗周期趋势 ]                     |
|                   |   (SectorMark 环形占比)             |   (BarMark 渐变柱状趋势)                |
|                   |                                     |                                         |
| ───────────────── | 🏆 Top 项目消耗排行榜                                              共 12 个项目 |
| 🟢 4 Agent 正常   | 🥇 #1 bennett-usage        ████████████████████████████ 100%    8.2M · $2.75 |
| 上次同步: 刚刚     | 🥈 #2 session-control      ████████████ 45%                     3.7M · $1.24 |
| [🔄 立即同步]     | 🥉 #3 fspeptide_real       ██████ 22%                           1.8M · $0.61 |
+-------------------+-----------------------------------------------------------------------------+
```

#### Settings View Layout
```
+-------------------------------------------------------------------------------------------------+
| ⚙️ 系统设置 (SettingsContentView)                                                                 |
| 管理多语言、Agent 本地接入状态、货币计价规则与本地数据库                                             |
+-------------------------------------------------------------------------------------------------+
| 🌐 通用设置 (General)                                                                            |
|   界面语言 (Language)                      [ 🇨🇳 简体中文 (跟随系统) ▾ ]                           |
|   自动刷新频率 (Auto Refresh)              [ 30 秒 ▾ ] (可选: 手动 / 10s / 30s / 60s)              |
+-------------------------------------------------------------------------------------------------+
| 🤖 Agent 数据源接入与状态诊断 (Agent Health & Detection)                                         |
|   检测本地各 AI 编程 Agent 的日志目录与解析状态                        [ 🔄 立即重新扫描同步 ]       |
|                                                                                                 |
|   🟢 Pi Agent           ~/.pi/agent/sessions/          已收录 1,420 条记录 · 状态正常            |
|   🟢 Oh My Pi           ~/.omp/sessions/               已收录 860 条记录 · 状态正常              |
|   🟢 Claude Code        ~/.claude/projects/            已收录 3,120 条记录 · 状态正常            |
|   🟢 OpenAI Codex       ~/.codex/sessions/             已收录 540 条记录 · 状态正常              |
+-------------------------------------------------------------------------------------------------+
| 💰 计价与货币 (Pricing & Currency)                                                               |
|   USD ⇄ CNY 参考汇率                       [ 7.30 ] (支持自定义汇率)                             |
|   主显示币种                               (○) 美元 USD ($)    ( ) 人民币 CNY (¥)                |
|   说明: 计费模型参考官方公布的标准费率（Sonnet / GPT-4 / DeepSeek），支持 Prompt、Cache 及 Output。 |
+-------------------------------------------------------------------------------------------------+
| 💾 数据存储与维护 (Storage & Maintenance)                                                        |
|   存储位置: ~/Library/Application Support/BennettUsage/bennett_usage.db                         |
|   数据库状态: 5,940 条用量记录 · 占用空间约 1.2 MB                                               |
|                                                                                                 |
|   [ 📂 在访达中打开数据目录 ]      [ ⚡ 重建聚合统计 ]      [ 🗑️ 清空所有记录... (带二次确认) ]    |
+-------------------------------------------------------------------------------------------------+
| ℹ️ 关于 Bennett Usage                                                                            |
|   [⚡ Bennett Usage]  版本 1.1.0 (Build 2026.09)                                                |
|   专为 macOS 开发者打造的本地优先 (Local-First) AI Agent Token 用量与成本追踪系统。                  |
|   · 100% 本地数据库存储，不收集任何代码、Prompt 与密钥                                          |
|   [ 🔗 GitHub 仓库 ]      [ 📄 开源许可 (MIT) ]                                                 |
+-------------------------------------------------------------------------------------------------+
```

---

## 3. Detailed Data Models & State Contracts

### 3.1 Navigation Route State
```swift
public enum NavigationItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case settings

    public var id: String { rawValue }
}
```

### 3.2 MetricsAggregator Filtering Extension
`MetricsAggregator` will be extended with an optional `toolFilter: String? = nil` parameter across:
- `fetchPeriodMetrics(range: TimeRangeOption, toolFilter: String? = nil) async throws -> PeriodMetrics`
- `fetchHeatmap(range: TimeRangeOption, toolFilter: String? = nil) async throws -> [HeatmapDayCell]`

When `toolFilter` is provided:
- Queries against `unified_token_records` and `daily_rollups` apply an additional `AND (LOWER(source_id) = LOWER(?))` condition;
- The returned `PeriodMetrics` accurately aggregates `totalTokens`, `totalCostUSD`, `trendPoints`, and `projectRankings` strictly for that agent;
- The `HeatmapDayCell` list recalculates cell intensity based on the filtered token volume.

### 3.3 Dynamic Pricing & Currency State
In `PricingEngine`:
- `usdToCnyRate`: Stored in `UserDefaults.standard` under key `"bennett_usd_to_cny_rate"`, defaulting to `7.30`;
- `preferredCurrency`: Stored in `UserDefaults.standard` under key `"bennett_preferred_currency"`, supporting `.usd` or `.cny`;
- `spendString(_ costUSD: Double) -> String`: Formats dual-currency string reflecting user preference:
  - If USD preferred: `"$4.82 (¥35.19)"`
  - If CNY preferred: `"¥35.19 ($4.82)"`

### 3.4 Agent Health Diagnostics Model
```swift
public struct AgentHealthInfo: Identifiable, Sendable {
    public let id: String                 // "pi", "omp", "claude", "codex"
    public let displayName: String        // "Pi Agent", "Oh My Pi", etc.
    public let defaultPath: String        // e.g. "~/.claude/projects"
    public let isInstalled: Bool          // FileManager.default.fileExists(atPath:)
    public let recordCount: Int           // Total rows in SQLite
    public let lastRecordTimestamp: Date? // Most recent log timestamp
}
```

---

## 4. UI/UX Implementation Details

### 4.1 Color Tokens & Theming
- **Pi Agent**: Emerald Green (`Color(red: 0.06, green: 0.73, blue: 0.51)`)
- **Oh My Pi**: Amber Gold (`Color(red: 0.96, green: 0.62, blue: 0.04)`)
- **Claude Code**: Coral Terracotta (`Color(red: 0.91, green: 0.44, blue: 0.32)`)
- **OpenAI Codex**: Deep Sky Blue (`Color(red: 0.05, green: 0.65, blue: 0.91)`)
- **Backgrounds**: Grouped inset cards with `Color(NSColor.controlBackgroundColor)` and soft border `Color.secondary.opacity(0.12)` with `cornerRadius: 12`.
- **Active State Ring**: Capsule buttons have an active stroke `Color.accentColor` or matching brand color when selected.

### 4.2 Interaction Rules
- **Heatmap Day Inspection**:
  - Clicking any active cell selects it and renders the inline day banner below the heatmap;
  - Clicking the same cell again or clicking the `[✕]` clear button dismisses the focus and restores the aggregate range view.
- **Top Projects Drill-Down**:
  - Top 3 rows receive special rank badges (#1 Gold, #2 Silver, #3 Bronze);
  - Relative volume progress bars indicate the ratio against the top project's token volume.
- **Manual Rescan**:
  - Triggering "Rescan Now" from sidebar or settings triggers `SyncCoordinator.shared.syncAll(incremental: true)` in a non-blocking `Task`;
  - Triggers an animated rotation on the sync icon and refreshes all metrics upon completion.

---

## 5. Localization Expansion (`LocalizationKey`)

The following keys will be added to `LocalizationKey` with complete English and Chinese translations:
- `navDashboard`: "用量看板" / "Dashboard"
- `navSettings`: "系统设置" / "Settings"
- `agentsConnected`: "%d 个 Agent 正常" / "%d Agents Connected"
- `rescanNow`: "立即同步" / "Sync Now"
- `syncedJustNow`: "刚刚同步" / "Synced just now"
- `syncedMinutesAgo`: "%d 分钟前同步" / "Synced %d mins ago"
- `filterAllAgents`: "全部 Agent" / "All Agents"
- `clearFocus`: "清除聚焦" / "Clear Focus"
- `agentHealthSection`: "Agent 数据源接入与状态诊断" / "Agent Data Sources & Health Diagnostics"
- `pricingSection`: "计价与货币" / "Pricing & Currency"
- `storageSection`: "数据存储与维护" / "Storage & Maintenance"
- `exchangeRateLabel`: "USD ⇄ CNY 参考汇率" / "USD ⇄ CNY Exchange Rate"
- `preferredCurrencyLabel`: "主显示币种" / "Preferred Currency"
- `revealInFinder`: "在访达中显示" / "Reveal in Finder"
- `rebuildRollups`: "重新聚合数据" / "Rebuild Aggregates"
- `clearAllRecords`: "清空所有记录..." / "Clear All Records..."
- `clearRecordsConfirmTitle`: "确定清空所有本地用量记录？" / "Clear All Local Usage Records?"
- `clearRecordsConfirmMessage`: "此操作将重置本地记录数据库。若 Agent 原始日志仍然存在，下次同步将重新扫描收录。" / "This will reset the local database. If raw agent logs remain, they will be rescanned on next sync."
- `autoRefreshLabel`: "自动刷新频率" / "Auto Refresh Interval"
- `autoRefreshOff`: "手动刷新" / "Manual"
- `autoRefreshSeconds`: "%d 秒" / "%d seconds"
- `storageStatus`: "%d 条用量记录 · 占用空间约 %@" / "%d records · %@ on disk"

---

## 6. Testing & Quality Assurance Plan

### 6.1 Unit Tests
- `DashboardViewTests`:
  - Verify `NavigationSplitView` initializes with `.dashboard` selected by default.
  - Verify `showSettingsInitially: true` selects `.settings`.
  - Verify switching navigation items updates the visible view.
- `SettingsContentViewTests`:
  - Verify language selection triggers `LocalizationManager` update.
  - Verify USD/CNY exchange rate input persists to `UserDefaults`.
  - Verify agent health diagnostics detect paths and report accurate counts.
- `MetricsAggregatorTests`:
  - Verify `fetchPeriodMetrics` with `toolFilter: "claude"` returns metrics only for Claude records.
  - Verify project rankings filter to projects touched by that agent.
- `LocalizationTests`:
  - Automated test iterating through all `LocalizationKey.allCases`, asserting that both `zh-Hans` and `en` dictionaries have non-empty definitions.

### 6.2 Regression & Build Verification
- Execute `swift test` ensuring all existing tests (including `EndToEndSmokeTests`, `StorageTests`, `SyncCoordinatorTests`) and all new tests pass with zero failures.

---

## 7. Migration & Rollout Strategy
1. The new `NavigationSplitView` becomes the primary window content in `DashboardView.swift`.
2. Existing call sites (e.g. `DashboardWindowManager.swift` and `MenuBarPopoverView.swift`) continue to construct `DashboardView(aggregator: localization:)` without signature breakage.
3. `SettingsSheetView` remains as a lightweight wrapper around `SettingsContentView` for sheet presentation, preserving backward compatibility.
