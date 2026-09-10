# Multi-Agent Token Usage & Activity Dashboard (macOS)
## Technical Design Specification

- **Date**: 2026-09-11
- **Target Platform**: macOS 14.0+ (Sonoma, Sequoia)
- **Tech Stack**: Swift 6, SwiftUI, Swift Charts, SQLite (GRDB.swift / Native SQLite C API), FSEvents
- **Repository**: `bennett-usage`
- **Application Type**: Native macOS Menu Bar Item + Standalone Dashboard Window

---

## 1. Executive Summary & Goals

### 1.1 Overview
The **Bennett Usage** dashboard is a high-performance, low-power native macOS application designed to query, aggregate, and visualize token consumption and cost across diverse AI agent tools—initially supporting **Oh My Pi (`omp`)**, **Pi Agent (`pi`)**, **Claude Code (`claude`)**, and **OpenAI Codex (`codex`)**.

The system is built around an open, pluggable adapter architecture (`AgentSourceAdapter`), allowing future coding agents and AI CLI tools to be seamlessly integrated with minimal effort.

### 1.2 Key Objectives
1. **Unified Observability**: Ingest heterogeneous logs (SQLite databases, streaming JSONL session logs, JSON files) into a normalized local schema.
2. **Dual-Surface User Experience**:
   - **Menu Bar Companion**: Quick glance at today's token total and cost, live status, and lightweight popover.
   - **Deep-Dive Dashboard Window**: Full analytics suite featuring a **GitHub-style annual contribution heatmap (365 days)**, tool usage donut charts, time-series stacked area charts, and project-level drill-down rankings.
3. **Pluggable & Extensible**: Adding support for a new agent requires implementing only a single Swift adapter struct/class without touching the storage, sync engine, or UI components.
4. **Extreme Performance & Low Footprint**: Zero CPU consumption when idle; sub-5ms annual heatmap rendering via materialized daily rollups; non-blocking incremental ingestion using native `FSEvents` and byte/row cursors.

---

## 2. System Architecture

### 2.1 Layered Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Presentation Layer (SwiftUI + Swift Charts)                         │
│    • StatusItemController & MenuBarPopoverView (Quick Glance)          │
│    • DashboardMainWindow & HeatmapGridView (Deep Dive Analytics)       │
│    • SettingsView (Adapter directories, custom pricing rules)          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Observable ViewModel State
┌───────────────────────────────────▼────────────────────────────────────┐
│ 2. Domain & Analytics Layer                                            │
│    • MetricsAggregator (Heatmap cell scoring, time-series, rankings)   │
│    • PricingEngine (Token-to-cost conversion, multi-currency support)  │
│    • SyncCoordinator (Actor managing ingestion lifecycle & debouncing) │
└───────────────────┬────────────────────────────────▲───────────────────┘
                    │ Writes normalized batches       │ Reads indexed data
┌───────────────────▼────────────────────────────────┴───────────────────┐
│ 3. Local Persistence Layer (SQLite + WAL Mode)                         │
│    • Table `unified_token_records` (Fine-grained transaction logs)     │
│    • Table `daily_rollups` (Materialized daily totals for instant heatmaps)
│    • Table `sync_cursors` (Persistent state tracking for all adapters) │
└───────────────────────────────────▲────────────────────────────────────┘
                                    │ Emits UnifiedTokenRecord
┌───────────────────────────────────┴────────────────────────────────────┐
│ 4. Extensible Adapter Layer (Protocol & Registry)                      │
│    • AgentSourceAdapter Protocol                                       │
│    • OmpAdapter        • PiAdapter                                     │
│    • ClaudeAdapter     • CodexAdapter                                  │
│    • [FutureToolAdapters...] (Zero-overhead pluggability)             │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Design

### 3.1 Adapter Protocol & Extension Architecture

Every AI agent tool logs tokens differently. The `AgentSourceAdapter` protocol normalizes these differences into a standard contract:

```swift
import Foundation

/// Normalized representation of a token consumption event
public struct UnifiedTokenRecord: Identifiable, Sendable, Codable {
    public let id: String                 // Composite unique ID (e.g., "omp_18293")
    public let sourceId: String           // Tool ID (e.g., "omp", "pi", "claude", "codex")
    public let timestamp: Date            // Event timestamp
    public let dayKey: String             // "YYYY-MM-DD" formatted for fast group-by
    public let sessionKey: String         // Unique session identifier
    public let projectFolder: String?     // Absolute path of the workspace project
    public let model: String              // Model string (e.g. "claude-3-5-sonnet")
    public let provider: String?          // Provider name (e.g. "anthropic", "openai")
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    public let rawCostUSD: Double?        // Upstream cost if already computed, else nil
}

/// Persistent cursor for incremental parsing
public enum SyncCursor: Codable, Sendable {
    case rowId(Int64)
    case fileOffsets([String: Int64])     // Map of absolute filePath -> byte offset
    case timestamp(Date)
}

/// Unified contract for all agent data sources
public protocol AgentSourceAdapter: Sendable {
    var sourceId: String { get }
    var displayName: String { get }
    var brandColorHex: String { get }
    var sfSymbolIcon: String { get }
    
    /// Detects the standard storage directory on macOS
    func detectDefaultPath() -> URL?
    
    /// Reads new records since the last known cursor
    func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor)
}
```

#### Adapter Registry
A centralized registry manages active adapters:
```swift
public final class AdapterRegistry: @unchecked Sendable {
    public static let shared = AdapterRegistry()
    private var adapters: [String: AgentSourceAdapter] = [:]
    private let lock = NSLock()

    public func register(_ adapter: AgentSourceAdapter) {
        lock.lock(); defer { lock.unlock() }
        adapters[adapter.sourceId] = adapter
    }

    public func get(sourceId: String) -> AgentSourceAdapter? {
        lock.lock(); defer { lock.unlock() }
        return adapters[sourceId]
    }

    public func allAdapters() -> [AgentSourceAdapter] {
        lock.lock(); defer { lock.unlock() }
        return Array(adapters.values)
    }
}
```

### 3.2 Core Tool Adapters Specification

1. **`OmpAdapter` (Oh My Pi)**
   - **Path**: `~/.omp/stats.db`
   - **Format**: SQLite (`messages` table).
   - **Incremental Logic**: Cursor stores `max(id)`. Query executes:
     `SELECT * FROM messages WHERE id > :lastId ORDER BY id ASC LIMIT 5000`.
   - **Mapping**:
     - `total_tokens`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`.
     - `rawCostUSD` maps directly to `cost_total`.
     - `projectFolder` maps to `folder`.
     - `model` maps to `model`.

2. **`PiAdapter` (Pi Coding Agent)**
   - **Path**: `~/.pi/agent/sessions/`
   - **Format**: Multiple subdirectories containing `*.jsonl` files (e.g. `--Users-ruanbw-projects-bennett--/YYYY-MM-DD...jsonl`).
   - **Incremental Logic**: Cursor maintains a `[String: Int64]` mapping of file paths to byte offsets. For each active or newly updated file, opens file handle, calls `seek(toOffset:)`, reads new lines, parses JSON message records with `usage` objects.
   - **Folder Detection**: Extracted from the encoded parent directory name or session metadata.

3. **`ClaudeAdapter` (Claude Code CLI)**
   - **Path**: `~/.claude` (and `~/.claude/projects/`)
   - **Format**: JSON session state and execution transcript files.
   - **Incremental Logic**: Scans project transcripts by modification date and message ID cursors.

4. **`CodexAdapter` (OpenAI Codex / CLI)**
   - **Path**: Configured Codex workspace / session store.
   - **Incremental Logic**: Parses structured CLI logs or API invocation records.

---

### 3.3 Storage Engine & Database Schema

The app utilizes a local SQLite database stored in:
`~/Library/Application Support/BennettUsage/usage.db`
Configured with:
- `PRAGMA journal_mode = WAL;`
- `PRAGMA synchronous = NORMAL;`
- `PRAGMA foreign_keys = ON;`

#### Schema Definitions:
```sql
CREATE TABLE IF NOT EXISTS unified_token_records (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    day_key TEXT NOT NULL,
    session_key TEXT NOT NULL,
    project_folder TEXT,
    model TEXT NOT NULL,
    provider TEXT,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cache_read_tokens INTEGER NOT NULL,
    cache_write_tokens INTEGER NOT NULL,
    total_tokens INTEGER NOT NULL,
    cost_usd REAL NOT NULL DEFAULT 0.0
);

CREATE INDEX IF NOT EXISTS idx_records_day_source ON unified_token_records(day_key, source_id);
CREATE INDEX IF NOT EXISTS idx_records_timestamp ON unified_token_records(timestamp);
CREATE INDEX IF NOT EXISTS idx_records_project ON unified_token_records(project_folder);
CREATE INDEX IF NOT EXISTS idx_records_model ON unified_token_records(model);

CREATE TABLE IF NOT EXISTS sync_cursors (
    source_id TEXT PRIMARY KEY,
    cursor_payload BLOB NOT NULL,
    last_synced_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS daily_rollups (
    day_key TEXT NOT NULL,
    source_id TEXT NOT NULL,
    total_tokens INTEGER NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cache_tokens INTEGER NOT NULL,
    cost_usd REAL NOT NULL,
    PRIMARY KEY (day_key, source_id)
);
```

#### Materialized Ingestion Trigger / Transaction:
Whenever a batch of `UnifiedTokenRecord` is written:
1. Insert records with `INSERT OR IGNORE INTO unified_token_records`.
2. Upsert corresponding `daily_rollups`:
   ```sql
   INSERT INTO daily_rollups (day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd)
   VALUES (:day, :source, :total, :input, :output, :cache, :cost)
   ON CONFLICT(day_key, source_id) DO UPDATE SET
       total_tokens = total_tokens + excluded.total_tokens,
       input_tokens = input_tokens + excluded.input_tokens,
       output_tokens = output_tokens + excluded.output_tokens,
       cache_tokens = cache_tokens + excluded.cache_tokens,
       cost_usd = cost_usd + excluded.cost_usd;
   ```
3. Commit cursor update in the same atomic transaction.

---

### 3.4 Ingestion Engine & File System Watcher

- **FSEvents Integration**: The `SyncCoordinator` actor initializes an `FSEventStream` covering the data directories of all registered adapters.
- **Debounce Mechanism**: Token streams output frequent updates. An asynchronous debouncer coalesces events across 1.5 seconds.
- **Error Isolation**: Failure in a single adapter does not halt or corrupt the sync of other adapters.

---

### 3.5 Pricing & Currency Engine

- **Default Rates Matrix**:
  - Claude 3.7 / 3.5 Sonnet: Input $3.00/M, Output $15.00/M, Cache Read $0.30/M, Cache Write $3.75/M.
  - Claude 3.5 Haiku: Input $0.80/M, Output $4.00/M, Cache Read $0.08/M, Cache Write $1.00/M.
  - GPT-4o: Input $2.50/M, Output $10.00/M, Cache Read $1.25/M.
  - DeepSeek V3: Input $0.14/M, Output $0.28/M, Cache Read $0.014/M.
- **Fuzzy Matching**: Matches model strings via pattern rules (e.g. `claude-3-5-sonnet*`).
- **Currency Conversion**: Live or user-configured USD-to-CNY exchange rate (default: 7.20).

---

## 4. UI/UX Design Specification

### 4.1 Surface 1: Menu Bar Item & Quick-Glance Popover
- **Menu Bar Icon**: Minimal status symbol (`sparkles` or custom token coin).
- **Menu Bar Title**: Configurable:
  - Mode 1: Icon only
  - Mode 2: Icon + Today's Tokens (e.g. `⚡️ 142.5k`)
  - Mode 3: Icon + Today's Cost (e.g. `$0.38`)
- **Popover Contents (Width: 320pt)**:
  - Header: Today's Token Total, Today's Estimated Cost.
  - Per-Tool Mini Progress Bars: Proportional colored segments for OMP, Pi, Claude, Codex.
  - Recent Agent Callouts: Last 2-3 sessions with model name, time elapsed, tokens used.
  - Action Bar: Open Dashboard (`⌘D`), Force Sync Now (`⌘R`), Preferences (`⌘,`), Quit (`⌘Q`).

### 4.2 Surface 2: Standalone Analytics Dashboard Window
- **Dimensions**: 1000pt × 680pt, supports macOS native window tabbing and resizing.
- **KPI Summary Cards**:
  1. Annual Tokens Total
  2. Today's Tokens Total
  3. Total Estimated Spend ($ / ¥)
  4. Most Active Agent Tool
- **GitHub-Style Contribution Heatmap**:
  - Layout: 52 columns (weeks) × 7 rows (days of week).
  - Cell Visuals: 11pt × 11pt squares with 3pt corner radii and 3pt spacing.
  - Color Intensity Scale:
    - Level 0: Inactive background
    - Level 1: Light activity (Quantile 1-33%)
    - Level 2: Moderate activity (Quantile 34-66%)
    - Level 3: High activity (Quantile 67-90%)
    - Level 4: Peak activity (Quantile > 90%)
  - Hover Interaction: Tooltip presenting exact date, token breakdown (input/output/cache), cost, and tool percentages.
  - Click Interaction: Selects the date and filters the breakdown tables below to that specific day.
- **Analytical Charts (Swift Charts)**:
  - **Tool Share Donut Chart**: Proportional breakdown of tool usage.
  - **Stacked Time Trend**: Daily or weekly token volume stacked by agent tool.
- **Project Drill-Down List**:
  - Top workspace directories ranked by total tokens and cost.

---

## 5. Reliability, Edge Cases & Security

| Scenario | Edge Case Behavior | Solution |
|---|---|---|
| **Active Token Streaming** | Incomplete trailing JSON line in `.jsonl` | Reader verifies trailing `\n` and valid JSON; rolls back byte offset if line is partial. |
| **Database Locks** | Agent process writing to `stats.db` | Open with `SQLITE_OPEN_READONLY` + WAL mode + 3000ms busy timeout. |
| **Massive Cold Start** | 100k+ historical messages | Ingest in background task with progress state; Menu Bar UI stays 100% responsive. |
| **New / Custom Models** | Unrecognized model names | Fallback to prefix matching; fallback to $0 with an `Unpriced` tag, prompt user in settings. |
| **macOS Permissions** | Accessing hidden directories (`~/.omp`, `~/.pi`) | Disable App Sandbox (`App Sandbox = NO`), matching standard developer tools (OrbStack, Raycast). |

---

## 6. Implementation Roadmap

1. **Phase 1: Project Skeleton & Storage Core**
   - Initialize Xcode / Swift Package structure.
   - Configure SQLite database, WAL mode, migrations, and tables.
2. **Phase 2: Adapter Layer & Ingestion Engine**
   - Implement `AgentSourceAdapter` and `AdapterRegistry`.
   - Implement `OmpAdapter` and `PiAdapter`.
   - Implement `FSEvents` watcher and `SyncCoordinator`.
3. **Phase 3: Domain Metrics & Pricing Engine**
   - Implement `PricingEngine` with default pricing matrix and currency conversion.
   - Implement `MetricsAggregator` with daily rollup queries and heatmap scale algorithms.
4. **Phase 4: SwiftUI Presentation Layer**
   - Build Menu Bar status item and popover view.
   - Build GitHub-style Heatmap grid component with hover tooltips and selection state.
   - Build Dashboard main window with KPI cards, Swift Charts, and project rankings.
5. **Phase 5: Claude & Codex Adapters + Preferences**
   - Implement `ClaudeAdapter` and `CodexAdapter`.
   - Implement settings view for custom pricing and directory management.
6. **Phase 6: Verification & Polish**
   - End-to-end integration tests using real `~/.omp/stats.db` and `~/.pi/` data.
   - Performance tuning and idle resource verification.
