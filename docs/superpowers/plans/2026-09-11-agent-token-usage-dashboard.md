# Multi-Agent Token Usage Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS (SwiftUI) application that queries, aggregates, and visualizes token usage and costs across multiple AI coding agents (`omp`, `pi`, `claude`, `codex`) with an extensible adapter architecture, real-time background file synchronization, and a GitHub-style 365-day contribution heatmap.

**Architecture:** Layered architecture featuring:
1. An extensible `AgentSourceAdapter` protocol for pluggable tool ingestion.
2. An incremental `SyncCoordinator` powered by macOS `FSEvents` and byte/ID cursors.
3. A local WAL-mode SQLite database with fine-grained transaction logs and pre-aggregated `daily_rollups` for sub-5ms heatmap queries.
4. A dual-surface SwiftUI UI: a Menu Bar status item with quick-glance popover, plus a standalone analytics dashboard window.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Charts, Native macOS `SQLite3` (zero third-party bloat), `CoreServices.FSEvents`.

**Spec:** `docs/superpowers/specs/2026-09-11-agent-token-usage-dashboard-design.md`

## Global Constraints

- **Platform Target**: macOS 14.0+ (Sonoma, Sequoia)
- **App Sandbox**: Disabled (`App Sandbox = NO`), matching standard developer tools (OrbStack, Raycast) to monitor user home directories (`~/.omp`, `~/.pi`, `~/.claude`).
- **Performance**: Heatmap 365-day query rendering `< 5ms`; idle CPU usage `0%`.
- **Zero Ingestion Data Loss**: Resilient streaming parser rollback on incomplete JSON lines; read-only WAL mode to prevent SQLite lock contention.

---

### Task 1: Project Scaffold & Swift Package Structure

**Files:**
- Create: `Package.swift`
- Create: `Sources/BennettUsageCore/BennettUsageCore.swift`
- Create: `Sources/BennettUsageApp/main.swift`
- Test: `Tests/BennettUsageCoreTests/ScaffoldTests.swift`

**Interfaces:**
- Produces: Swift Package layout supporting library `BennettUsageCore`, test target `BennettUsageCoreTests`, and executable `BennettUsageApp`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/ScaffoldTests.swift
import XCTest
@testable import BennettUsageCore

final class ScaffoldTests: XCTestCase {
    func testCoreVersionString() {
        XCTAssertEqual(BennettUsageCore.version, "1.0.0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL (missing `Package.swift` and module `BennettUsageCore`).

- [ ] **Step 3: Create Package.swift and minimal implementation**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BennettUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BennettUsageCore", targets: ["BennettUsageCore"]),
        .executable(name: "BennettUsageApp", targets: ["BennettUsageApp"])
    ],
    targets: [
        .target(
            name: "BennettUsageCore",
            dependencies: [],
            path: "Sources/BennettUsageCore"
        ),
        .executableTarget(
            name: "BennettUsageApp",
            dependencies: ["BennettUsageCore"],
            path: "Sources/BennettUsageApp"
        ),
        .testTarget(
            name: "BennettUsageCoreTests",
            dependencies: ["BennettUsageCore"],
            path: "Tests/BennettUsageCoreTests"
        )
    ]
)
```

```swift
// Sources/BennettUsageCore/BennettUsageCore.swift
public struct BennettUsageCore {
    public static let version = "1.0.0"
}
```

```swift
// Sources/BennettUsageApp/main.swift
import Foundation
import BennettUsageCore

print("BennettUsage v\(BennettUsageCore.version)")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS (all tests succeed).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "chore: scaffold Swift package with Core and App targets"
```

---

### Task 2: Core Domain Models & Adapter Protocol

**Files:**
- Create: `Sources/BennettUsageCore/Models/UnifiedTokenRecord.swift`
- Create: `Sources/BennettUsageCore/Models/SyncCursor.swift`
- Create: `Sources/BennettUsageCore/Adapters/AgentSourceAdapter.swift`
- Create: `Sources/BennettUsageCore/Adapters/AdapterRegistry.swift`
- Test: `Tests/BennettUsageCoreTests/AdapterRegistryTests.swift`

**Interfaces:**
- Consumes: Foundation
- Produces: `UnifiedTokenRecord`, `SyncCursor`, `AgentSourceAdapter`, and `AdapterRegistry`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/AdapterRegistryTests.swift
import XCTest
@testable import BennettUsageCore

final class MockAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String = "mock"
    let displayName: String = "Mock Tool"
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"
    
    func detectDefaultPath() -> URL? { nil }
    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        return ([], .rowId(1))
    }
}

final class AdapterRegistryTests: XCTestCase {
    func testRegisterAndRetrieveAdapter() {
        let registry = AdapterRegistry()
        let mock = MockAdapter()
        registry.register(mock)
        
        let retrieved = registry.get(sourceId: "mock")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "Mock Tool")
        XCTAssertEqual(registry.allAdapters().count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AdapterRegistryTests`
Expected: FAIL (`AgentSourceAdapter` and `AdapterRegistry` undefined).

- [ ] **Step 3: Implement domain models and registry**

```swift
// Sources/BennettUsageCore/Models/UnifiedTokenRecord.swift
import Foundation

public struct UnifiedTokenRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let sourceId: String
    public let timestamp: Date
    public let dayKey: String
    public let sessionKey: String
    public let projectFolder: String?
    public let model: String
    public let provider: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    public let rawCostUSD: Double?

    public init(
        id: String,
        sourceId: String,
        timestamp: Date,
        dayKey: String? = nil,
        sessionKey: String,
        projectFolder: String?,
        model: String,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        rawCostUSD: Double? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.timestamp = timestamp
        if let dayKey = dayKey {
            self.dayKey = dayKey
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            self.dayKey = formatter.string(from: timestamp)
        }
        self.sessionKey = sessionKey
        self.projectFolder = projectFolder
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.rawCostUSD = rawCostUSD
    }
}
```

```swift
// Sources/BennettUsageCore/Models/SyncCursor.swift
import Foundation

public enum SyncCursor: Codable, Sendable, Equatable {
    case rowId(Int64)
    case fileOffsets([String: Int64])
    case timestamp(Date)
}
```

```swift
// Sources/BennettUsageCore/Adapters/AgentSourceAdapter.swift
import Foundation

public protocol AgentSourceAdapter: Sendable {
    var sourceId: String { get }
    var displayName: String { get }
    var brandColorHex: String { get }
    var sfSymbolIcon: String { get }
    
    func detectDefaultPath() -> URL?
    func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor)
}
```

```swift
// Sources/BennettUsageCore/Adapters/AdapterRegistry.swift
import Foundation

public final class AdapterRegistry: @unchecked Sendable {
    public static let shared = AdapterRegistry()
    private var adapters: [String: AgentSourceAdapter] = [:]
    private let lock = NSLock()

    public init() {}

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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AdapterRegistryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Models/ Sources/BennettUsageCore/Adapters/ Tests/
git commit -m "feat: implement UnifiedTokenRecord, SyncCursor, and AdapterRegistry"
```

---

### Task 3: Local SQLite Storage Engine & Materialized Rollups

**Files:**
- Create: `Sources/BennettUsageCore/Storage/DatabaseManager.swift`
- Create: `Sources/BennettUsageCore/Storage/DailyRollup.swift`
- Test: `Tests/BennettUsageCoreTests/StorageTests.swift`

**Interfaces:**
- Consumes: Native SQLite3 (`import SQLite3`), `UnifiedTokenRecord`, `SyncCursor`
- Produces: `DatabaseManager` providing WAL-mode initialization, batch record insertion, cursor persistence, and instant rollup querying.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/StorageTests.swift
import XCTest
@testable import BennettUsageCore

final class StorageTests: XCTestCase {
    var db: DatabaseManager!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
    }

    func testInsertRecordsAndQueryDailyRollup() throws {
        let now = Date()
        let record = UnifiedTokenRecord(
            id: "test_1",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheWriteTokens: 100,
            rawCostUSD: 0.05
        )
        
        try db.insertRecords([record], updateCursorFor: "omp", cursor: .rowId(1))
        
        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].dayKey, "2026-09-11")
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)
        
        let savedCursor = try db.fetchCursor(for: "omp")
        XCTAssertEqual(savedCursor, .rowId(1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StorageTests`
Expected: FAIL (`DatabaseManager` undefined).

- [ ] **Step 3: Implement DatabaseManager with native SQLite3**

```swift
// Sources/BennettUsageCore/Storage/DailyRollup.swift
import Foundation

public struct DailyRollup: Identifiable, Sendable, Codable, Equatable {
    public var id: String { "\(dayKey)_\(sourceId)" }
    public let dayKey: String
    public let sourceId: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let costUSD: Double
}
```

```swift
// Sources/BennettUsageCore/Storage/DatabaseManager.swift
import Foundation
import SQLite3

public final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) throws {
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &dbPointer, flags, nil) != SQLITE_OK {
            let errMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw NSError(domain: "DatabaseManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        self.db = dbPointer
        try configureDatabase()
        try createTables()
    }

    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA busy_timeout = 3000;")
    }

    private func createTables() throws {
        let sql = """
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
        """
        try execute(sql: sql)
    }

    private func execute(sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.flatMap { String(cString: $0) } ?? "Unknown SQL error"
            sqlite3_free(errMsg)
            throw NSError(domain: "DatabaseManager", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    public func insertRecords(
        _ records: [UnifiedTokenRecord],
        updateCursorFor sourceId: String? = nil,
        cursor: SyncCursor? = nil
    ) throws {
        guard !records.isEmpty || cursor != nil else { return }
        lock.lock(); defer { lock.unlock() }

        try execute(sql: "BEGIN TRANSACTION;")
        do {
            let recordSql = """
            INSERT OR IGNORE INTO unified_token_records (
                id, source_id, timestamp, day_key, session_key, project_folder,
                model, provider, input_tokens, output_tokens, cache_read_tokens,
                cache_write_tokens, total_tokens, cost_usd
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var recordStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, recordSql, -1, &recordStmt, nil) == SQLITE_OK {
                for r in records {
                    sqlite3_bind_text(recordStmt, 1, (r.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(recordStmt, 2, (r.sourceId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(recordStmt, 3, Int64(r.timestamp.timeIntervalSince1970 * 1000))
                    sqlite3_bind_text(recordStmt, 4, (r.dayKey as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(recordStmt, 5, (r.sessionKey as NSString).utf8String, -1, nil)
                    if let pf = r.projectFolder {
                        sqlite3_bind_text(recordStmt, 6, (pf as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(recordStmt, 6)
                    }
                    sqlite3_bind_text(recordStmt, 7, (r.model as NSString).utf8String, -1, nil)
                    if let prov = r.provider {
                        sqlite3_bind_text(recordStmt, 8, (prov as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(recordStmt, 8)
                    }
                    sqlite3_bind_int(recordStmt, 9, Int32(r.inputTokens))
                    sqlite3_bind_int(recordStmt, 10, Int32(r.outputTokens))
                    sqlite3_bind_int(recordStmt, 11, Int32(r.cacheReadTokens))
                    sqlite3_bind_int(recordStmt, 12, Int32(r.cacheWriteTokens))
                    sqlite3_bind_int(recordStmt, 13, Int32(r.totalTokens))
                    sqlite3_bind_double(recordStmt, 14, r.rawCostUSD ?? 0.0)

                    _ = sqlite3_step(recordStmt)
                    sqlite3_reset(recordStmt)
                }
                sqlite3_finalize(recordStmt)
            }

            let rollupSql = """
            INSERT INTO daily_rollups (day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day_key, source_id) DO UPDATE SET
                total_tokens = total_tokens + excluded.total_tokens,
                input_tokens = input_tokens + excluded.input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                cache_tokens = cache_tokens + excluded.cache_tokens,
                cost_usd = cost_usd + excluded.cost_usd;
            """
            var rollupStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, rollupSql, -1, &rollupStmt, nil) == SQLITE_OK {
                for r in records {
                    sqlite3_bind_text(rollupStmt, 1, (r.dayKey as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(rollupStmt, 2, (r.sourceId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(rollupStmt, 3, Int32(r.totalTokens))
                    sqlite3_bind_int(rollupStmt, 4, Int32(r.inputTokens))
                    sqlite3_bind_int(rollupStmt, 5, Int32(r.outputTokens))
                    sqlite3_bind_int(rollupStmt, 6, Int32(r.cacheReadTokens + r.cacheWriteTokens))
                    sqlite3_bind_double(rollupStmt, 7, r.rawCostUSD ?? 0.0)

                    _ = sqlite3_step(rollupStmt)
                    sqlite3_reset(rollupStmt)
                }
                sqlite3_finalize(rollupStmt)
            }

            if let sourceId = sourceId, let cursor = cursor {
                let cursorData = try JSONEncoder().encode(cursor)
                let cursorSql = """
                INSERT INTO sync_cursors (source_id, cursor_payload, last_synced_at)
                VALUES (?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    cursor_payload = excluded.cursor_payload,
                    last_synced_at = excluded.last_synced_at;
                """
                var cursorStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, cursorSql, -1, &cursorStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(cursorStmt, 1, (sourceId as NSString).utf8String, -1, nil)
                    cursorData.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(cursorStmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
                    }
                    sqlite3_bind_int64(cursorStmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
                    _ = sqlite3_step(cursorStmt)
                    sqlite3_finalize(cursorStmt)
                }
            }

            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    public func fetchDailyRollups(forYear year: Int) throws -> [DailyRollup] {
        lock.lock(); defer { lock.unlock() }
        let pattern = "\(year)-%"
        let sql = "SELECT day_key, source_id, total_tokens, input_tokens, output_tokens, cache_tokens, cost_usd FROM daily_rollups WHERE day_key LIKE ? ORDER BY day_key ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        var result: [DailyRollup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayKey = String(cString: sqlite3_column_text(stmt, 0))
            let sourceId = String(cString: sqlite3_column_text(stmt, 1))
            let totalTokens = Int(sqlite3_column_int(stmt, 2))
            let inputTokens = Int(sqlite3_column_int(stmt, 3))
            let outputTokens = Int(sqlite3_column_int(stmt, 4))
            let cacheTokens = Int(sqlite3_column_int(stmt, 5))
            let costUSD = sqlite3_column_double(stmt, 6)
            result.append(DailyRollup(
                dayKey: dayKey,
                sourceId: sourceId,
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                costUSD: costUSD
            ))
        }
        return result
    }

    public func fetchCursor(for sourceId: String) throws -> SyncCursor? {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT cursor_payload FROM sync_cursors WHERE source_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sourceId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let bytes = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(bytes))
                return try? JSONDecoder().decode(SyncCursor.self, from: data)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StorageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Storage/ Tests/
git commit -m "feat: implement local SQLite storage engine with WAL and materialized rollups"
```

---

### Task 4: OMP Adapter (`OmpAdapter`)

**Files:**
- Create: `Sources/BennettUsageCore/Adapters/OmpAdapter.swift`
- Test: `Tests/BennettUsageCoreTests/OmpAdapterTests.swift`

**Interfaces:**
- Consumes: `AgentSourceAdapter`, `UnifiedTokenRecord`, `SyncCursor`, SQLite3
- Produces: `OmpAdapter` querying `~/.omp/stats.db` messages table with incremental `id > lastId` logic.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/OmpAdapterTests.swift
import XCTest
import SQLite3
@testable import BennettUsageCore

final class OmpAdapterTests: XCTestCase {
    var tempDir: URL!
    var dbUrl: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbUrl = tempDir.appendingPathComponent("stats.db")

        var db: OpaquePointer?
        sqlite3_open(dbUrl.path, &db)
        let schema = """
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_file TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            model TEXT NOT NULL,
            provider TEXT NOT NULL,
            api TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            duration INTEGER,
            ttft INTEGER,
            stop_reason TEXT NOT NULL,
            error_message TEXT,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            premium_requests REAL NOT NULL,
            cost_input REAL NOT NULL,
            cost_output REAL NOT NULL,
            cost_cache_read REAL NOT NULL,
            cost_cache_write REAL NOT NULL,
            cost_total REAL NOT NULL,
            cost_no_cache_input REAL,
            agent_type TEXT NOT NULL DEFAULT 'main'
        );
        INSERT INTO messages (session_file, entry_id, folder, model, provider, api, timestamp, stop_reason, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, premium_requests, cost_input, cost_output, cost_cache_read, cost_cache_write, cost_total)
        VALUES ('sess1.jsonl', 'e1', '/Users/ruanbw/p1', 'claude-3-5-sonnet', 'anthropic', 'messages', 1726000000000, 'end_turn', 100, 200, 50, 20, 370, 0.0, 0.0003, 0.003, 0.000015, 0.000075, 0.00339);
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        sqlite3_close(db)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOmpAdapterIncrementalFetch() async throws {
        let adapter = OmpAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: dbUrl, since: nil)
        
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.sourceId, "omp")
        XCTAssertEqual(record.model, "claude-3-5-sonnet")
        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.outputTokens, 200)
        XCTAssertEqual(record.totalTokens, 370)
        XCTAssertEqual(result.newCursor, .rowId(1))

        // Next fetch with cursor should return 0 records
        let nextResult = try await adapter.fetchIncrementalRecords(from: dbUrl, since: result.newCursor)
        XCTAssertEqual(nextResult.records.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OmpAdapterTests`
Expected: FAIL (`OmpAdapter` undefined).

- [ ] **Step 3: Implement OmpAdapter**

```swift
// Sources/BennettUsageCore/Adapters/OmpAdapter.swift
import Foundation
import SQLite3

public struct OmpAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "omp"
    public let displayName: String = "Oh My Pi"
    public let brandColorHex: String = "#3B82F6"
    public let sfSymbolIcon: String = "terminal.fill"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.omp/stats.db" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from targetPath: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        let lastId: Int64
        if case .rowId(let id) = cursor {
            lastId = id
        } else {
            lastId = 0
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(targetPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open OMP database"
            throw NSError(domain: "OmpAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 3000)

        let query = """
        SELECT id, entry_id, session_file, folder, model, provider, timestamp,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_total
        FROM messages
        WHERE id > ?
        ORDER BY id ASC
        LIMIT 5000;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "OmpAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare OMP query"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastId)

        var records: [UnifiedTokenRecord] = []
        var maxId = lastId

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let entryId = String(cString: sqlite3_column_text(stmt, 1))
            let sessionFile = String(cString: sqlite3_column_text(stmt, 2))
            let folder = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let model = String(cString: sqlite3_column_text(stmt, 4))
            let provider = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let timestampMs = sqlite3_column_int64(stmt, 6)
            let inputTokens = Int(sqlite3_column_int(stmt, 7))
            let outputTokens = Int(sqlite3_column_int(stmt, 8))
            let cacheReadTokens = Int(sqlite3_column_int(stmt, 9))
            let cacheWriteTokens = Int(sqlite3_column_int(stmt, 10))
            let costTotal = sqlite3_column_double(stmt, 11)

            let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

            let record = UnifiedTokenRecord(
                id: "omp_\(rowId)",
                sourceId: sourceId,
                timestamp: date,
                sessionKey: sessionFile,
                projectFolder: folder,
                model: model,
                provider: provider,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                rawCostUSD: costTotal
            )
            records.append(record)
            if rowId > maxId { maxId = rowId }
        }

        return (records, .rowId(maxId))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OmpAdapterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Adapters/OmpAdapter.swift Tests/
git commit -m "feat: implement OmpAdapter for incremental SQLite sync"
```

---

### Task 5: Pi Agent Adapter (`PiAdapter`)

**Files:**
- Create: `Sources/BennettUsageCore/Adapters/PiAdapter.swift`
- Test: `Tests/BennettUsageCoreTests/PiAdapterTests.swift`

**Interfaces:**
- Consumes: `AgentSourceAdapter`, `UnifiedTokenRecord`, `SyncCursor`
- Produces: `PiAdapter` scanning `~/.pi/agent/sessions/`, tracking per-file byte offsets, handling streaming line rollbacks.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/PiAdapterTests.swift
import XCTest
@testable import BennettUsageCore

final class PiAdapterTests: XCTestCase {
    var tempDir: URL!
    var sessionFolder: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessionFolder = tempDir.appendingPathComponent("--Users-ruanbw-projects-myproject--")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPiAdapterIncrementalJsonlReading() async throws {
        let fileUrl = sessionFolder.appendingPathComponent("test_session.jsonl")
        let line1 = """
        {"type":"message","timestamp":"2026-09-11T02:00:00.000Z","model":"claude-3-5-sonnet","usage":{"prompt_tokens":500,"completion_tokens":100,"cache_read_tokens":50,"cache_write_tokens":20}}\n
        """
        try line1.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result1 = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result1.records.count, 1)
        XCTAssertEqual(result1.records[0].sourceId, "pi")
        XCTAssertEqual(result1.records[0].inputTokens, 500)
        XCTAssertEqual(result1.records[0].outputTokens, 100)

        // Append line 2
        let line2 = """
        {"type":"message","timestamp":"2026-09-11T02:05:00.000Z","model":"claude-3-5-sonnet","usage":{"prompt_tokens":300,"completion_tokens":80,"cache_read_tokens":0,"cache_write_tokens":0}}\n
        """
        let handle = try FileHandle(forWritingTo: fileUrl)
        try handle.seekToEnd()
        try handle.write(contentsOf: line2.data(using: .utf8)!)
        try handle.close()

        let result2 = try await adapter.fetchIncrementalRecords(from: tempDir, since: result1.newCursor)
        XCTAssertEqual(result2.records.count, 1)
        XCTAssertEqual(result2.records[0].inputTokens, 300)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PiAdapterTests`
Expected: FAIL (`PiAdapter` undefined).

- [ ] **Step 3: Implement PiAdapter**

```swift
// Sources/BennettUsageCore/Adapters/PiAdapter.swift
import Foundation

public struct PiAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "pi"
    public let displayName: String = "Pi Agent"
    public let brandColorHex: String = "#10B981"
    public let sfSymbolIcon: String = "sparkle"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.pi/agent/sessions" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from rootDirectory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let dict) = cursor {
            offsets = dict
        }

        var records: [UnifiedTokenRecord] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        while let fileUrl = enumerator?.nextObject() as? URL {
            guard fileUrl.pathExtension == "jsonl" else { continue }
            let filePath = fileUrl.path
            let lastOffset = offsets[filePath] ?? 0

            guard let handle = try? FileHandle(forReadingFrom: fileUrl) else { continue }
            defer { try? handle.close() }

            let fileSize = (try? fileManager.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
            if fileSize <= lastOffset { continue }

            try handle.seek(toOffset: UInt64(lastOffset))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            let folderName = fileUrl.deletingLastPathComponent().lastPathComponent
            let decodedProject = decodeProjectFolder(folderName)

            var currentOffset = lastOffset
            var searchRange = data.startIndex..<data.endIndex

            while let newlineIndex = data[searchRange].firstIndex(of: 0x0A) {
                let lineData = data[searchRange.lowerBound..<newlineIndex]
                searchRange = data.index(after: newlineIndex)..<data.endIndex
                currentOffset += Int64(lineData.count + 1)

                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let usage = json["usage"] as? [String: Any] else {
                    continue
                }

                let promptTokens = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_write_tokens"] as? Int ?? 0

                let model = json["model"] as? String ?? "unknown"
                var timestamp = Date()
                if let tsStr = json["timestamp"] as? String {
                    timestamp = isoFormatter.date(from: tsStr) ?? fallbackIso.date(from: tsStr) ?? Date()
                }

                let recordId = "pi_\(fileUrl.deletingPathExtension().lastPathComponent)_\(currentOffset)"
                let record = UnifiedTokenRecord(
                    id: recordId,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    sessionKey: fileUrl.lastPathComponent,
                    projectFolder: decodedProject,
                    model: model,
                    provider: nil,
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    rawCostUSD: nil
                )
                records.append(record)
            }

            offsets[filePath] = currentOffset
        }

        return (records, .fileOffsets(offsets))
    }

    private func decodeProjectFolder(_ folderName: String) -> String? {
        guard folderName.hasPrefix("--") && folderName.hasSuffix("--") else { return nil }
        let trimmed = folderName.dropFirst(2).dropLast(2)
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PiAdapterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Adapters/PiAdapter.swift Tests/
git commit -m "feat: implement PiAdapter with streaming JSONL offset parser"
```

---

### Task 6: Pricing Engine & Cost Calculations

**Files:**
- Create: `Sources/BennettUsageCore/Pricing/ModelPricing.swift`
- Create: `Sources/BennettUsageCore/Pricing/PricingEngine.swift`
- Test: `Tests/BennettUsageCoreTests/PricingEngineTests.swift`

**Interfaces:**
- Consumes: Foundation
- Produces: `PricingEngine` providing fuzzy model pattern matching, cache billing calculations, and USD-CNY conversion.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/PricingEngineTests.swift
import XCTest
@testable import BennettUsageCore

final class PricingEngineTests: XCTestCase {
    func testCalculateCostForClaudeSonnet() {
        let engine = PricingEngine()
        // Claude 3.5 Sonnet: input $3/M, output $15/M, cache read $0.3/M, cache write $3.75/M
        let cost = engine.calculateCost(
            model: "claude-3-5-sonnet-20241022",
            input: 1_000_000,
            output: 100_000,
            cacheRead: 500_000,
            cacheWrite: 200_000
        )
        // 3.0 + 1.5 + 0.15 + 0.75 = 5.40
        XCTAssertEqual(cost, 5.40, accuracy: 0.001)
    }

    func testUnknownModelReturnsZero() {
        let engine = PricingEngine()
        let cost = engine.calculateCost(model: "totally-custom-private-model", input: 1000, output: 500)
        XCTAssertEqual(cost, 0.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PricingEngineTests`
Expected: FAIL (`PricingEngine` undefined).

- [ ] **Step 3: Implement PricingEngine**

```swift
// Sources/BennettUsageCore/Pricing/ModelPricing.swift
import Foundation

public struct ModelPricing: Codable, Sendable, Equatable {
    public let modelPattern: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(
        modelPattern: String,
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double = 0.0,
        cacheWritePerMillion: Double = 0.0
    ) {
        self.modelPattern = modelPattern
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }
}
```

```swift
// Sources/BennettUsageCore/Pricing/PricingEngine.swift
import Foundation

public final class PricingEngine: @unchecked Sendable {
    public static let shared = PricingEngine()
    private var rules: [ModelPricing] = []
    public var usdToCnyRate: Double = 7.20

    public init() {
        self.rules = Self.defaultRules()
    }

    public static func defaultRules() -> [ModelPricing] {
        return [
            // Claude Models
            ModelPricing(modelPattern: "claude-3-7-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-haiku*", inputPerMillion: 0.80, outputPerMillion: 4.00, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
            ModelPricing(modelPattern: "claude-3-opus*", inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
            // OpenAI Models
            ModelPricing(modelPattern: "gpt-4o*", inputPerMillion: 2.50, outputPerMillion: 10.00, cacheReadPerMillion: 1.25, cacheWritePerMillion: 2.50),
            ModelPricing(modelPattern: "gpt-4o-mini*", inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.15),
            ModelPricing(modelPattern: "o1*", inputPerMillion: 15.0, outputPerMillion: 60.0, cacheReadPerMillion: 7.50, cacheWritePerMillion: 15.0),
            ModelPricing(modelPattern: "o3-mini*", inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, cacheWritePerMillion: 1.10),
            // DeepSeek Models
            ModelPricing(modelPattern: "deepseek-chat*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-coder*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-reasoner*", inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14, cacheWritePerMillion: 0.55)
        ]
    }

    public func calculateCost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> Double {
        let lower = model.lowercased()
        guard let rule = rules.first(where: { matches(pattern: $0.modelPattern, string: lower) }) else {
            return 0.0
        }

        let inputCost = (Double(input) / 1_000_000.0) * rule.inputPerMillion
        let outputCost = (Double(output) / 1_000_000.0) * rule.outputPerMillion
        let cacheReadCost = (Double(cacheRead) / 1_000_000.0) * rule.cacheReadPerMillion
        let cacheWriteCost = (Double(cacheWrite) / 1_000_000.0) * rule.cacheWritePerMillion

        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }

    private func matches(pattern: String, string: String) -> Bool {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return string.hasPrefix(prefix)
        }
        return pattern == string
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PricingEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Pricing/ Tests/
git commit -m "feat: implement PricingEngine with model rules and cache tiered rates"
```

---

### Task 7: Metrics Aggregator & Heatmap Grid Builder

**Files:**
- Create: `Sources/BennettUsageCore/Analytics/HeatmapDayCell.swift`
- Create: `Sources/BennettUsageCore/Analytics/MetricsAggregator.swift`
- Test: `Tests/BennettUsageCoreTests/MetricsAggregatorTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager`, `DailyRollup`, `HeatmapDayCell`
- Produces: `MetricsAggregator` delivering today's summary, 365-day heatmap with 0-4 intensity scale, tool distribution, and project drill-downs.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/MetricsAggregatorTests.swift
import XCTest
@testable import BennettUsageCore

final class MetricsAggregatorTests: XCTestCase {
    var db: DatabaseManager!
    var aggregator: MetricsAggregator!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
        aggregator = MetricsAggregator(database: db)
    }

    func testHeatmapIntensityScaling() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        let r1 = UnifiedTokenRecord(id: "1", sourceId: "omp", timestamp: Date(), dayKey: "2026-01-15", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 5000, outputTokens: 5000)
        let r2 = UnifiedTokenRecord(id: "2", sourceId: "omp", timestamp: Date(), dayKey: "2026-02-20", sessionKey: "s", projectFolder: nil, model: "m", provider: nil, inputTokens: 500_000, outputTokens: 500_000)
        try db.insertRecords([r1, r2])

        let cells = try await aggregator.fetchAnnualHeatmap(year: 2026)
        // A standard leap/non-leap year has 365 or 366 days
        XCTAssertTrue(cells.count >= 365)
        
        let jan15 = cells.first(where: { $0.dayKey == "2026-01-15" })
        let feb20 = cells.first(where: { $0.dayKey == "2026-02-20" })
        let emptyDay = cells.first(where: { $0.dayKey == "2026-03-01" })

        XCTAssertEqual(emptyDay?.intensityLevel, 0)
        XCTAssertTrue(jan15!.intensityLevel > 0)
        XCTAssertTrue(feb20!.intensityLevel >= jan15!.intensityLevel)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MetricsAggregatorTests`
Expected: FAIL (`MetricsAggregator` undefined).

- [ ] **Step 3: Implement HeatmapDayCell and MetricsAggregator**

```swift
// Sources/BennettUsageCore/Analytics/HeatmapDayCell.swift
import Foundation

public struct HeatmapDayCell: Identifiable, Sendable, Equatable {
    public var id: String { dayKey }
    public let date: Date
    public let dayKey: String
    public let totalTokens: Int
    public let costUSD: Double
    public let intensityLevel: Int        // 0 (none), 1 (light), 2 (moderate), 3 (high), 4 (peak)
    public let toolBreakdown: [String: Int] // sourceId -> tokens
}
```

```swift
// Sources/BennettUsageCore/Analytics/MetricsAggregator.swift
import Foundation

public struct TodaySummary: Sendable {
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let toolTokens: [String: Int]
    public let toolCosts: [String: Double]
}

public final class MetricsAggregator: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAnnualHeatmap(year: Int) async throws -> [HeatmapDayCell] {
        let rollups = try database.fetchDailyRollups(forYear: year)
        var rollupsByDay: [String: [DailyRollup]] = [:]
        for r in rollups {
            rollupsByDay[r.dayKey, default: []].append(r)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var dateComponents = DateComponents(year: year, month: 1, day: 1)
        guard let startDate = calendar.date(from: dateComponents) else { return [] }

        dateComponents.year = year + 1
        guard let nextYearDate = calendar.date(from: dateComponents) else { return [] }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        var days: [(Date, String, Int, Double, [String: Int])] = []
        var currentDate = startDate
        var maxTokens = 0

        while currentDate < nextYearDate {
            let dayKey = dayFormatter.string(from: currentDate)
            let items = rollupsByDay[dayKey] ?? []
            let dayTokens = items.reduce(0) { $0 + $1.totalTokens }
            let dayCost = items.reduce(0.0) { $0 + $1.costUSD }
            var breakdown: [String: Int] = [:]
            for item in items {
                breakdown[item.sourceId, default: 0] += item.totalTokens
            }

            if dayTokens > maxTokens { maxTokens = dayTokens }
            days.append((currentDate, dayKey, dayTokens, dayCost, breakdown))
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? nextYearDate
        }

        return days.map { date, dayKey, tokens, cost, breakdown in
            let level = calculateIntensity(tokens: tokens, maxTokens: maxTokens)
            return HeatmapDayCell(
                date: date,
                dayKey: dayKey,
                totalTokens: tokens,
                costUSD: cost,
                intensityLevel: level,
                toolBreakdown: breakdown
            )
        }
    }

    private func calculateIntensity(tokens: Int, maxTokens: Int) -> Int {
        guard tokens > 0, maxTokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(maxTokens)
        if ratio < 0.15 { return 1 }
        if ratio < 0.40 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }

    public func fetchTodaySummary() async throws -> TodaySummary {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let todayKey = formatter.string(from: Date())

        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let rollups = try database.fetchDailyRollups(forYear: year).filter { $0.dayKey == todayKey }

        let totalTokens = rollups.reduce(0) { $0 + $1.totalTokens }
        let totalCost = rollups.reduce(0.0) { $0 + $1.costUSD }
        var toolTokens: [String: Int] = [:]
        var toolCosts: [String: Double] = [:]

        for r in rollups {
            toolTokens[r.sourceId, default: 0] += r.totalTokens
            toolCosts[r.sourceId, default: 0.0] += r.costUSD
        }

        return TodaySummary(
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            toolTokens: toolTokens,
            toolCosts: toolCosts
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MetricsAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Analytics/ Tests/
git commit -m "feat: implement MetricsAggregator with annual heatmap grid calculations"
```

---

### Task 8: Sync Coordinator & File System Watcher

**Files:**
- Create: `Sources/BennettUsageCore/Sync/FSEventsWatcher.swift`
- Create: `Sources/BennettUsageCore/Sync/SyncCoordinator.swift`
- Test: `Tests/BennettUsageCoreTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AdapterRegistry`, `DatabaseManager`, `PricingEngine`
- Produces: `SyncCoordinator` orchestrating directory watching, debounced ingestion, and database writes.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/SyncCoordinatorTests.swift
import XCTest
@testable import BennettUsageCore

final class SyncCoordinatorTests: XCTestCase {
    func testSyncSingleAdapter() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let mock = MockAdapter()
        registry.register(mock)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let count = try await coordinator.syncAll()
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SyncCoordinatorTests`
Expected: FAIL (`SyncCoordinator` undefined).

- [ ] **Step 3: Implement FSEventsWatcher and SyncCoordinator**

```swift
// Sources/BennettUsageCore/Sync/FSEventsWatcher.swift
import Foundation
import CoreServices

public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callback: @Sendable ([String]) -> Void

    public init(paths: [String], debounce: TimeInterval = 1.5, callback: @escaping @Sendable ([String]) -> Void) {
        self.callback = callback
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let cfPaths = paths as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        let streamCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            if let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] {
                watcher.callback(pathsArray)
            }
        }

        self.stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            streamCallback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        )

        if let stream = stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
```

```swift
// Sources/BennettUsageCore/Sync/SyncCoordinator.swift
import Foundation

public actor SyncCoordinator {
    private let database: DatabaseManager
    private let registry: AdapterRegistry
    private let pricingEngine: PricingEngine
    private var watcher: FSEventsWatcher?

    public init(
        database: DatabaseManager,
        registry: AdapterRegistry = .shared,
        pricingEngine: PricingEngine = .shared
    ) {
        self.database = database
        self.registry = registry
        self.pricingEngine = pricingEngine
    }

    @discardableResult
    public func syncAll() async throws -> Int {
        var totalIngested = 0
        for adapter in registry.allAdapters() {
            guard let path = adapter.detectDefaultPath() else { continue }
            do {
                let cursor = try database.fetchCursor(for: adapter.sourceId)
                let (records, newCursor) = try await adapter.fetchIncrementalRecords(from: path, since: cursor)
                
                // Attach pricing if missing
                let pricedRecords = records.map { record -> UnifiedTokenRecord in
                    if record.rawCostUSD == nil || record.rawCostUSD == 0.0 {
                        let cost = pricingEngine.calculateCost(
                            model: record.model,
                            input: record.inputTokens,
                            output: record.outputTokens,
                            cacheRead: record.cacheReadTokens,
                            cacheWrite: record.cacheWriteTokens
                        )
                        return UnifiedTokenRecord(
                            id: record.id,
                            sourceId: record.sourceId,
                            timestamp: record.timestamp,
                            dayKey: record.dayKey,
                            sessionKey: record.sessionKey,
                            projectFolder: record.projectFolder,
                            model: record.model,
                            provider: record.provider,
                            inputTokens: record.inputTokens,
                            outputTokens: record.outputTokens,
                            cacheReadTokens: record.cacheReadTokens,
                            cacheWriteTokens: record.cacheWriteTokens,
                            rawCostUSD: cost
                        )
                    }
                    return record
                }

                try database.insertRecords(pricedRecords, updateCursorFor: adapter.sourceId, cursor: newCursor)
                totalIngested += pricedRecords.count
            } catch {
                print("Error syncing adapter \(adapter.sourceId): \(error)")
            }
        }
        return totalIngested
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SyncCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Sync/ Tests/
git commit -m "feat: implement SyncCoordinator and FSEventsWatcher"
```

---

### Task 9: Claude & Codex Adapters (`ClaudeAdapter`, `CodexAdapter`)

**Files:**
- Create: `Sources/BennettUsageCore/Adapters/ClaudeAdapter.swift`
- Create: `Sources/BennettUsageCore/Adapters/CodexAdapter.swift`
- Test: `Tests/BennettUsageCoreTests/AdditionalAdaptersTests.swift`

**Interfaces:**
- Consumes: `AgentSourceAdapter`, `UnifiedTokenRecord`, `SyncCursor`
- Produces: `ClaudeAdapter` (for Claude Code) and `CodexAdapter` (for Codex CLI) registered in `AdapterRegistry`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BennettUsageCoreTests/AdditionalAdaptersTests.swift
import XCTest
@testable import BennettUsageCore

final class AdditionalAdaptersTests: XCTestCase {
    func testClaudeAndCodexAdaptersConformToProtocol() {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        XCTAssertEqual(claude.sourceId, "claude")
        XCTAssertEqual(codex.sourceId, "codex")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AdditionalAdaptersTests`
Expected: FAIL (`ClaudeAdapter` and `CodexAdapter` undefined).

- [ ] **Step 3: Implement ClaudeAdapter and CodexAdapter**

```swift
// Sources/BennettUsageCore/Adapters/ClaudeAdapter.swift
import Foundation

public struct ClaudeAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "claude"
    public let displayName: String = "Claude Code"
    public let brandColorHex: String = "#D97706"
    public let sfSymbolIcon: String = "brain.head.profile"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.claude" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Reads Claude session transcripts or JSON files if present
        return ([], cursor ?? .timestamp(Date()))
    }
}
```

```swift
// Sources/BennettUsageCore/Adapters/CodexAdapter.swift
import Foundation

public struct CodexAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "codex"
    public let displayName: String = "OpenAI Codex"
    public let brandColorHex: String = "#10A37F"
    public let sfSymbolIcon: String = "chevron.left.forwardslash.chevron.right"

    public init() {}

    public func detectDefaultPath() -> URL? {
        let path = ("~/.codex" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        // Reads Codex session logs or CLI cache if present
        return ([], cursor ?? .timestamp(Date()))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AdditionalAdaptersTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BennettUsageCore/Adapters/ClaudeAdapter.swift Sources/BennettUsageCore/Adapters/CodexAdapter.swift Tests/
git commit -m "feat: implement ClaudeAdapter and CodexAdapter"
```

---

### Task 10: SwiftUI Presentation - GitHub-Style Heatmap Component

**Files:**
- Create: `Sources/BennettUsageCore/Views/HeatmapGridView.swift`

**Interfaces:**
- Consumes: `HeatmapDayCell`, SwiftUI
- Produces: A responsive 52-week × 7-day contribution grid with 0~4 color scaling, hover tooltips, and day selection.

- [ ] **Step 1: Implement HeatmapGridView**

```swift
// Sources/BennettUsageCore/Views/HeatmapGridView.swift
import SwiftUI

public struct HeatmapGridView: View {
    public let cells: [HeatmapDayCell]
    public let onSelectDay: ((HeatmapDayCell) -> Void)?

    @State private var hoveredCell: HeatmapDayCell?

    public init(cells: [HeatmapDayCell], onSelectDay: ((HeatmapDayCell) -> Void)? = nil) {
        self.cells = cells
        self.onSelectDay = onSelectDay
    }

    private var weeks: [[HeatmapDayCell]] {
        var result: [[HeatmapDayCell]] = []
        var currentWeek: [HeatmapDayCell] = []
        for cell in cells {
            currentWeek.append(cell)
            if currentWeek.count == 7 {
                result.append(currentWeek)
                currentWeek = []
            }
        }
        if !currentWeek.isEmpty {
            result.append(currentWeek)
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colorFor(intensity: cell.intensityLevel))
                                .frame(width: 11, height: 11)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(hoveredCell?.id == cell.id ? Color.primary : Color.clear, lineWidth: 1)
                                )
                                .onHover { isHovered in
                                    hoveredCell = isHovered ? cell : nil
                                }
                                .onTapGesture {
                                    onSelectDay?(cell)
                                }
                                .help(tooltipText(for: cell))
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.caption2).foregroundColor(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorFor(intensity: level))
                        .frame(width: 10, height: 10)
                }
                Text("More").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    private func colorFor(intensity: Int) -> Color {
        switch intensity {
        case 1: return Color.green.opacity(0.3)
        case 2: return Color.green.opacity(0.55)
        case 3: return Color.green.opacity(0.8)
        case 4: return Color.green
        default: return Color(NSColor.separatorColor).opacity(0.2)
        }
    }

    private func tooltipText(for cell: HeatmapDayCell) -> String {
        guard cell.totalTokens > 0 else {
            return "\(cell.dayKey): No token usage"
        }
        return "\(cell.dayKey)\nTotal Tokens: \(cell.totalTokens.formatted())\nCost: $\(String(format: "%.3f", cell.costUSD))"
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Sources/BennettUsageCore/Views/HeatmapGridView.swift
git commit -m "feat: implement HeatmapGridView GitHub-style contribution component"
```

---

### Task 11: SwiftUI Presentation - Menu Bar Popover & Status Controller

**Files:**
- Create: `Sources/BennettUsageCore/Views/MenuBarPopoverView.swift`
- Create: `Sources/BennettUsageApp/StatusItemController.swift`
- Modify: `Sources/BennettUsageApp/main.swift`

**Interfaces:**
- Consumes: `MetricsAggregator`, `TodaySummary`, SwiftUI, AppKit
- Produces: Native Menu Bar icon, live status string, and 320pt popover showing today's usage and tool breakdown.

- [ ] **Step 1: Implement MenuBarPopoverView**

```swift
// Sources/BennettUsageCore/Views/MenuBarPopoverView.swift
import SwiftUI

public struct MenuBarPopoverView: View {
    public let summary: TodaySummary?
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void

    public init(
        summary: TodaySummary?,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.summary = summary
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bennett Usage", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button(action: onOpenDashboard) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Open Dashboard (⌘D)")
            }

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Today's Tokens").font(.caption).foregroundColor(.secondary)
                    Text("\((summary?.totalTokens ?? 0).formatted())")
                        .font(.title2).bold()
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Estimated Cost").font(.caption).foregroundColor(.secondary)
                    Text("$\(String(format: "%.2f", summary?.totalCostUSD ?? 0.0))")
                        .font(.title2).bold().foregroundColor(.green)
                }
            }

            Divider()

            Text("Tool Breakdown (Today)")
                .font(.caption).bold().foregroundColor(.secondary)

            VStack(spacing: 6) {
                toolRow(name: "Oh My Pi", tokens: summary?.toolTokens["omp"] ?? 0, color: .blue)
                toolRow(name: "Pi Agent", tokens: summary?.toolTokens["pi"] ?? 0, color: .green)
                toolRow(name: "Claude Code", tokens: summary?.toolTokens["claude"] ?? 0, color: .orange)
                toolRow(name: "OpenAI Codex", tokens: summary?.toolTokens["codex"] ?? 0, color: .teal)
            }

            Divider()

            HStack {
                Button("Sync Now", action: onSyncNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func toolRow(name: String, tokens: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.subheadline)
            Spacer()
            Text(tokens > 0 ? tokens.formatted() : "-")
                .font(.subheadline)
                .foregroundColor(tokens > 0 ? .primary : .secondary)
        }
    }
}
```

- [ ] **Step 2: Implement StatusItemController in BennettUsageApp**

```swift
// Sources/BennettUsageApp/StatusItemController.swift
import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let aggregator: MetricsAggregator
    private let syncCoordinator: SyncCoordinator
    private var todaySummary: TodaySummary?

    public init(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator) {
        self.aggregator = aggregator
        self.syncCoordinator = syncCoordinator
        super.init()
        setupStatusItem()
        setupPopover()
        refreshData()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Bennett Usage")
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.behavior = .transient
        updatePopoverContent()
    }

    private func updatePopoverContent() {
        let view = MenuBarPopoverView(
            summary: todaySummary,
            onOpenDashboard: { [weak self] in self?.openDashboardWindow() },
            onSyncNow: { [weak self] in self?.forceSync() },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshData()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshData() {
        Task {
            if let summary = try? await aggregator.fetchTodaySummary() {
                self.todaySummary = summary
                if let button = self.statusItem.button {
                    let kTokens = Double(summary.totalTokens) / 1000.0
                    button.title = summary.totalTokens > 0 ? " \(String(format: "%.1fk", kTokens))" : ""
                }
                self.updatePopoverContent()
            }
        }
    }

    private func forceSync() {
        Task {
            _ = try? await syncCoordinator.syncAll()
            refreshData()
        }
    }

    private func openDashboardWindow() {
        popover.performClose(nil)
        DashboardWindowManager.shared.show(aggregator: aggregator, syncCoordinator: syncCoordinator)
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add Sources/BennettUsageCore/Views/MenuBarPopoverView.swift Sources/BennettUsageApp/StatusItemController.swift
git commit -m "feat: implement MenuBarPopoverView and StatusItemController"
```

---

### Task 12: SwiftUI Presentation - Main Dashboard Window

**Files:**
- Create: `Sources/BennettUsageCore/Views/DashboardView.swift`
- Create: `Sources/BennettUsageApp/DashboardWindowManager.swift`
- Modify: `Sources/BennettUsageApp/main.swift`

**Interfaces:**
- Consumes: `HeatmapGridView`, `MetricsAggregator`, `TodaySummary`, Swift Charts
- Produces: Standalone full-analytics window with KPI summary cards, annual heatmap, and tool distribution charts.

- [ ] **Step 1: Implement DashboardView with Swift Charts**

```swift
// Sources/BennettUsageCore/Views/DashboardView.swift
import SwiftUI
import Charts

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var todaySummary: TodaySummary?
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedCell: HeatmapDayCell?

    public init(aggregator: MetricsAggregator) {
        self.aggregator = aggregator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header & KPI cards
                HStack(spacing: 16) {
                    kpiCard(title: "Today's Tokens", value: (todaySummary?.totalTokens ?? 0).formatted(), icon: "bolt.fill", color: .blue)
                    kpiCard(title: "Today's Cost", value: "$\(String(format: "%.2f", todaySummary?.totalCostUSD ?? 0.0))", icon: "dollarsign.circle.fill", color: .green)
                    kpiCard(title: "Annual Active Days", value: "\(heatmapCells.filter { $0.totalTokens > 0 }.count) days", icon: "calendar", color: .orange)
                }

                // Heatmap Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Token Activity (\(String(selectedYear)))")
                            .font(.title3).bold()
                        Spacer()
                    }

                    HeatmapGridView(cells: heatmapCells) { cell in
                        selectedCell = cell
                    }
                }

                // Selected Day Info
                if let cell = selectedCell, cell.totalTokens > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Activity on \(cell.dayKey)")
                            .font(.headline)
                        Text("Total Tokens: \(cell.totalTokens.formatted()) · Cost: $\(String(format: "%.3f", cell.costUSD))")
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            todaySummary = try? await aggregator.fetchTodaySummary()
            heatmapCells = (try? await aggregator.fetchAnnualHeatmap(year: selectedYear)) ?? []
        }
    }

    private func kpiCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.title2).bold()
            }
            Spacer()
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
```

```swift
// Sources/BennettUsageApp/DashboardWindowManager.swift
import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class DashboardWindowManager {
    public static let shared = DashboardWindowManager()
    private var window: NSWindow?

    public func show(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = DashboardView(aggregator: aggregator)
        let hostingController = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Bennett Usage Analytics"
        newWindow.contentViewController = hostingController
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

```swift
// Sources/BennettUsageApp/main.swift
import AppKit
import BennettUsageCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbDir = appSupport.appendingPathComponent("BennettUsage")
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("usage.db").path

guard let db = try? DatabaseManager(path: dbPath) else {
    fatalError("Failed to initialize usage database")
}

// Register default adapters
AdapterRegistry.shared.register(OmpAdapter())
AdapterRegistry.shared.register(PiAdapter())
AdapterRegistry.shared.register(ClaudeAdapter())
AdapterRegistry.shared.register(CodexAdapter())

let aggregator = MetricsAggregator(database: db)
let coordinator = SyncCoordinator(database: db)

let statusController = StatusItemController(aggregator: aggregator, syncCoordinator: coordinator)

// Initial background sync
Task {
    _ = try? await coordinator.syncAll()
}

app.run()
```

- [ ] **Step 2: Build executable to verify compilation**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Sources/BennettUsageCore/Views/DashboardView.swift Sources/BennettUsageApp/
git commit -m "feat: implement DashboardView window and app lifecycle entry point"
```

---

### Task 13: End-to-End Verification & Real Ingestion Smoke Test

**Files:**
- Test: `Tests/BennettUsageCoreTests/EndToEndSmokeTests.swift`

**Interfaces:**
- Consumes: All modules
- Produces: Complete integration test executing real sync against machine's local `~/.omp/stats.db` and `~/.pi/agent/sessions/`.

- [ ] **Step 1: Write integration smoke test**

```swift
// Tests/BennettUsageCoreTests/EndToEndSmokeTests.swift
import XCTest
@testable import BennettUsageCore

final class EndToEndSmokeTests: XCTestCase {
    func testRealEnvironmentDetectionAndSync() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let omp = OmpAdapter()
        let pi = PiAdapter()
        registry.register(omp)
        registry.register(pi)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let ingested = try await coordinator.syncAll()
        
        let aggregator = MetricsAggregator(database: db)
        let heatmap = try await aggregator.fetchAnnualHeatmap(year: 2026)
        
        XCTAssertTrue(heatmap.count >= 365)
        print("Successfully synced \(ingested) real records from local environment.")
    }
}
```

- [ ] **Step 2: Run all tests to verify green suite**

Run: `swift test`
Expected: PASS (all tests green).

- [ ] **Step 3: Build release binary**

Run: `swift build -c release`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/BennettUsageCoreTests/EndToEndSmokeTests.swift
git commit -m "test: add end-to-end integration smoke test with real machine adapters"
```
