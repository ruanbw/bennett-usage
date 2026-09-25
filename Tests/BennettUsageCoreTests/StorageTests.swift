import XCTest
import SQLite3
@testable import BennettUsageCore

final class StorageTests: XCTestCase {
    var db: DatabaseManager!

    override func setUp() async throws {
        db = try DatabaseManager.inMemory()
    }

    func testTimestampSourceDefaultsToEventAndRoundTrips() throws {
        let record = makeRollupTestRecord(input: 1, output: 1, cost: 0.01)
        XCTAssertEqual(record.timestampSource, .event)
        try db.insertRecords([record])
        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0).first?.timestampSource, .event)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(UnifiedTokenRecord.self, from: data)
        XCTAssertEqual(decoded.timestampSource, .event)
    }

    func testLegacyDatabaseMigratesTimestampSourceAndRemainsReadable() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &legacy), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(legacy, """
        CREATE TABLE unified_token_records (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, timestamp INTEGER NOT NULL,
            day_key TEXT NOT NULL, session_key TEXT NOT NULL, project_folder TEXT,
            model TEXT NOT NULL, provider TEXT, input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
            cost_usd REAL NOT NULL DEFAULT 0.0
        );
        INSERT INTO unified_token_records VALUES
            ('legacy', 'old', 1000, '1970-01-01', 'session', NULL, 'model', NULL, 1, 2, 0, 0, 3, 0.5);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacy)

        let database = try DatabaseManager(path: path)
        let saved = try XCTUnwrap(try database.fetchRecords(sinceTimestamp: 0).first)
        XCTAssertEqual(saved.id, "legacy")
        XCTAssertEqual(saved.timestampSource, .event)
        XCTAssertEqual(saved.totalTokens, 3)
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

    /// U-12 contract: `insertRecords` must report rows *actually* inserted.
    /// `INSERT OR IGNORE` dedupes by primary key, so re-parsing an unchanged
    /// log file must return 0 — otherwise `SyncCoordinator` posts
    /// `.bennettUsageDataDidUpdate` and the dashboard pays a full recompute for
    /// nothing (regression covered by U-12).
    func testInsertRecordsReturnsActualInsertedCount() throws {
        let now = Date()

        func makeRecord(id: String) -> UnifiedTokenRecord {
            UnifiedTokenRecord(
                id: id,
                sourceId: "omp",
                timestamp: now,
                dayKey: "2026-09-11",
                sessionKey: "sess_1",
                projectFolder: "/tmp/project",
                model: "claude-3-5-sonnet",
                provider: "anthropic",
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                rawCostUSD: 0.01
            )
        }

        let first = makeRecord(id: "dedupe_1")
        XCTAssertEqual(try db.insertRecords([first]), 1)

        // Same primary key re-parsed: not a new row, so nothing to notify about.
        XCTAssertEqual(try db.insertRecords([first]), 0)

        // Mixed batch counts only the genuinely new row.
        let second = makeRecord(id: "dedupe_2")
        XCTAssertEqual(try db.insertRecords([first, second]), 1)

        // The deduped rows were never double counted in records or rollups.
        XCTAssertEqual(try db.fetchTotalRecordCount(), 2)
        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 300)
    }

    func testCorrectionUpdatesRecordAndRollupByDifference() throws {
        let original = UnifiedTokenRecord(
            id: "corrected",
            sourceId: "continue",
            timestamp: Date(timeIntervalSince1970: 1_000),
            dayKey: "2026-09-11",
            sessionKey: "session-old",
            projectFolder: "/old",
            model: "old-model",
            provider: "old-provider",
            inputTokens: 10,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.20
        )
        let corrected = UnifiedTokenRecord(
            id: "corrected",
            sourceId: "continue",
            timestamp: Date(timeIntervalSince1970: 90_000),
            dayKey: "2026-09-12",
            sessionKey: "session-new",
            projectFolder: "/new",
            model: "new-model",
            provider: "new-provider",
            inputTokens: 25,
            outputTokens: 7,
            cacheReadTokens: 3,
            cacheWriteTokens: 2,
            rawCostUSD: 0.70
        )

        XCTAssertEqual(try db.insertRecords([original]), 1)
        XCTAssertEqual(try db.insertRecords([corrected], updateExisting: true), 1)
        XCTAssertEqual(try db.insertRecords([corrected], updateExisting: true), 0)

        let saved = try XCTUnwrap(try db.fetchRecords(sinceTimestamp: 0).first)
        XCTAssertEqual(saved.sourceId, corrected.sourceId)
        XCTAssertEqual(saved.timestamp.timeIntervalSince1970, corrected.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(saved.dayKey, corrected.dayKey)
        XCTAssertEqual(saved.sessionKey, corrected.sessionKey)
        XCTAssertEqual(saved.projectFolder, corrected.projectFolder)
        XCTAssertEqual(saved.model, corrected.model)
        XCTAssertEqual(saved.provider, corrected.provider)
        XCTAssertEqual(saved.inputTokens, corrected.inputTokens)
        XCTAssertEqual(saved.outputTokens, corrected.outputTokens)
        XCTAssertEqual(saved.cacheReadTokens, corrected.cacheReadTokens)
        XCTAssertEqual(saved.cacheWriteTokens, corrected.cacheWriteTokens)
        XCTAssertEqual(saved.rawCostUSD, corrected.rawCostUSD)

        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 2)
        let oldRollup = try XCTUnwrap(rollups.first { $0.dayKey == original.dayKey })
        XCTAssertEqual(oldRollup.totalTokens, 0)
        XCTAssertEqual(oldRollup.inputTokens, 0)
        XCTAssertEqual(oldRollup.outputTokens, 0)
        XCTAssertEqual(oldRollup.cacheTokens, 0)
        XCTAssertEqual(oldRollup.costUSD, 0)
        let newRollup = try XCTUnwrap(rollups.first { $0.dayKey == corrected.dayKey })
        XCTAssertEqual(newRollup.totalTokens, 37)
        XCTAssertEqual(newRollup.inputTokens, 25)
        XCTAssertEqual(newRollup.outputTokens, 7)
        XCTAssertEqual(newRollup.cacheTokens, 5)
        XCTAssertEqual(newRollup.costUSD, 0.70, accuracy: 0.000_001)
    }

    func testImmutableInsertModeKeepsExistingRecordAndRollup() throws {
        let original = makeRollupTestRecord(input: 10, output: 2, cost: 0.20)
        let replacement = makeRollupTestRecord(input: 25, output: 7, cost: 0.70)

        XCTAssertEqual(try db.insertRecords([original]), 1)
        XCTAssertEqual(try db.insertRecords([replacement]), 0)

        XCTAssertEqual(try db.fetchRecords(sinceTimestamp: 0), [original])
        let rollup = try XCTUnwrap(try db.fetchDailyRollups(forYear: 2026).first)
        XCTAssertEqual(rollup.totalTokens, 12)
        XCTAssertEqual(rollup.costUSD, 0.20, accuracy: 0.000_001)
    }

    private func makeRollupTestRecord(input: Int, output: Int, cost: Double) -> UnifiedTokenRecord {
        UnifiedTokenRecord(
            id: "immutable",
            sourceId: "immutable-source",
            timestamp: Date(timeIntervalSince1970: 1_000),
            dayKey: "2026-09-11",
            sessionKey: "session",
            projectFolder: nil,
            model: "model",
            provider: nil,
            inputTokens: input,
            outputTokens: output,
            rawCostUSD: cost
        )
    }

    func testRollupUpsertAccumulation() throws {
        let now = Date()
        let record1 = UnifiedTokenRecord(
            id: "test_1",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWriteTokens: 5,
            rawCostUSD: 0.01
        )
        let record2 = UnifiedTokenRecord(
            id: "test_2",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_1",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 200,
            outputTokens: 100,
            cacheReadTokens: 20,
            cacheWriteTokens: 10,
            rawCostUSD: 0.02
        )

        try db.insertRecords([record1, record2])

        let rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 495)
        XCTAssertEqual(rollups[0].inputTokens, 300)
        XCTAssertEqual(rollups[0].outputTokens, 150)
        XCTAssertEqual(rollups[0].cacheTokens, 45)
        XCTAssertEqual(rollups[0].costUSD, 0.03, accuracy: 0.0001)
    }

    func testYearFilterExcludesOtherYears() throws {
        let now = Date()
        let record2025 = UnifiedTokenRecord(
            id: "test_2025",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2025-12-31",
            sessionKey: "sess_old",
            projectFolder: nil,
            model: "claude-3",
            provider: nil,
            inputTokens: 50,
            outputTokens: 50
        )
        let record2026 = UnifiedTokenRecord(
            id: "test_2026",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-01-01",
            sessionKey: "sess_new",
            projectFolder: nil,
            model: "claude-3",
            provider: nil,
            inputTokens: 100,
            outputTokens: 100
        )

        try db.insertRecords([record2025, record2026])

        let rollups2025 = try db.fetchDailyRollups(forYear: 2025)
        XCTAssertEqual(rollups2025.count, 1)
        XCTAssertEqual(rollups2025[0].dayKey, "2025-12-31")

        let rollups2026 = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups2026.count, 1)
        XCTAssertEqual(rollups2026[0].dayKey, "2026-01-01")
    }
    func testDuplicateRecordInsertDoesNotDuplicateRollup() throws {
        let now = Date()
        let record = UnifiedTokenRecord(
            id: "test_dup",
            sourceId: "omp",
            timestamp: now,
            dayKey: "2026-09-11",
            sessionKey: "sess_dup",
            projectFolder: "/tmp/project",
            model: "claude-3-5-sonnet",
            provider: "anthropic",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheWriteTokens: 100,
            rawCostUSD: 0.05
        )

        try db.insertRecords([record])

        var rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)

        // Inserting duplicate record in separate call should be ignored and not increment rollup
        try db.insertRecords([record])

        rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)

        // Inserting same duplicate in a single batch should also not increment rollup
        try db.insertRecords([record, record])

        rollups = try db.fetchDailyRollups(forYear: 2026)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].totalTokens, 1800)
        XCTAssertEqual(rollups[0].costUSD, 0.05, accuracy: 0.0001)
    }

    func testFetchDailyRollupsDateRange() throws {
        let record1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-01",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 100, outputTokens: 50, rawCostUSD: 0.01
        )
        let record2 = UnifiedTokenRecord(
            id: "r2", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-05",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 200, outputTokens: 100, rawCostUSD: 0.02
        )
        let record3 = UnifiedTokenRecord(
            id: "r3", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-10",
            sessionKey: "s3", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 300, outputTokens: 150, rawCostUSD: 0.03
        )
        try db.insertRecords([record1, record2, record3])

        let rangeRollups = try db.fetchDailyRollups(startDate: "2026-09-03", endDate: "2026-09-08")
        XCTAssertEqual(rangeRollups.count, 1)
        XCTAssertEqual(rangeRollups[0].dayKey, "2026-09-05")
        XCTAssertEqual(rangeRollups[0].totalTokens, 300)
    }

    func testFetchRecordsSinceTimestamp() throws {
        let t0 = Date(timeIntervalSince1970: 1700000000)
        let t1 = Date(timeIntervalSince1970: 1700003600) // +1h
        let r1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: t0, dayKey: "2026-09-01",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        let r2 = UnifiedTokenRecord(
            id: "r2", sourceId: "pi", timestamp: t1, dayKey: "2026-09-01",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 20, outputTokens: 20
        )
        try db.insertRecords([r1, r2])

        let recent = try db.fetchRecords(sinceTimestamp: Int64(t1.timeIntervalSince1970 * 1000))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].id, "r2")
        XCTAssertEqual(recent[0].sourceId, "pi")
    }

    func testFetchAvailableYears() throws {
        let r1 = UnifiedTokenRecord(
            id: "r1", sourceId: "omp", timestamp: Date(), dayKey: "2025-12-31",
            sessionKey: "s1", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        let r2 = UnifiedTokenRecord(
            id: "r2", sourceId: "omp", timestamp: Date(), dayKey: "2026-09-01",
            sessionKey: "s2", projectFolder: "/proj", model: "m", provider: "p",
            inputTokens: 10, outputTokens: 10
        )
        try db.insertRecords([r1, r2])

        let years = try db.fetchAvailableYears()
        XCTAssertEqual(years, [2026, 2025])
    }

    func testDatabaseManagerSelfHealsDshCorruptRecords() throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("db").path
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let db1 = try DatabaseManager(path: tempPath)
        let corruptRecord = UnifiedTokenRecord(
            id: "dsh_corrupt_1",
            sourceId: "dsh",
            timestamp: Date(),
            dayKey: "2026-09-14",
            sessionKey: "s1",
            projectFolder: "/proj",
            model: "dsh",
            provider: "dsh",
            inputTokens: 100,
            outputTokens: 50
        )
        try db1.insertRecords([corruptRecord])
        let statsBefore = try db1.fetchRecordStats(forSourceId: "dsh")
        XCTAssertEqual(statsBefore.count, 1)

        // Reopen database: createTables triggers self-heal reset for "dsh"
        let db2 = try DatabaseManager(path: tempPath)
        let statsAfter = try db2.fetchRecordStats(forSourceId: "dsh")
        XCTAssertEqual(statsAfter.count, 0, "Corrupt 'dsh' records should be reset on init")
    }

    /// The write-ahead log used to stay at its high-water mark, because a process
    /// killed before its last checkpoint never runs `sqlite3_close` (692 MB was
    /// found on disk for a 62 MB database). `journal_size_limit` plus an explicit
    /// truncating checkpoint on the way out bounds it.
    func testCheckpointAndTruncateReclaimsTheWriteAheadLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("usage.db").path
        let database = try DatabaseManager(path: path)
        let record = UnifiedTokenRecord(
            id: "wal_1",
            sourceId: "pi",
            timestamp: Date(),
            dayKey: "2026-09-26",
            sessionKey: "session",
            projectFolder: nil,
            model: "gpt-4o",
            provider: nil,
            inputTokens: 10,
            outputTokens: 10,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            rawCostUSD: 0.01
        )
        _ = try database.insertRecords([record], updateCursorFor: "pi", cursor: .rowId(7))

        let walPath = path + "-wal"
        XCTAssertGreaterThan(walSize(at: walPath), 0, "The write-ahead log should hold the uncommitted frames")

        database.checkpointAndTruncate()
        XCTAssertEqual(walSize(at: walPath), 0)
    }

    private func walSize(at path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }
}
