import XCTest
import SQLite3
@testable import BennettUsageCore

final class GooseAdapterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testOfficialMinimumFixtureAndIncrementalCarriedForward() async throws {
        let databaseURL = try makeFixture()
        let adapter = GooseAdapter()
        let initial = try await adapter.fetchIncrementalRecords(from: databaseURL, since: nil)
        XCTAssertEqual(initial.records.count, 2)
        XCTAssertEqual(initial.records.reduce(0) { $0 + $1.totalTokens }, 35)
        XCTAssertEqual(initial.records.filter { $0.model == "goose" }.count, 1)
        XCTAssertEqual(initial.records.first(where: { $0.model == "goose" })?.totalTokens, 5)
        XCTAssertEqual(initial.records.first(where: { $0.model == "goose" })?.timestampSource, .unknown)
        XCTAssertEqual(initial.records.first(where: { $0.model == "gpt-x" })?.totalTokens, 30)
        XCTAssertEqual(initial.records.first(where: { $0.model == "gpt-x" })?.provider, "openai")
        XCTAssertEqual(initial.records.first(where: { $0.model == "gpt-x" })?.timestampSource, .event)
        try execute("""
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (2, 's1', 1780000060, NULL, 5, 0, 5, 0, 0, 0.001, 'carried_forward', 0),
          (3, 's1', 1780000061, 'gpt-x', 4, 1, 5, 0, 0, 0.002, 'estimated', 0);
        UPDATE sessions SET accumulated_input_tokens = 39,
                            accumulated_output_tokens = 6,
                            accumulated_total_tokens = 40,
                            accumulated_cost = 0.012;
        """, on: databaseURL)

        let incremental = try await adapter.fetchIncrementalRecords(from: databaseURL, since: initial.newCursor)
        XCTAssertEqual(incremental.records.count, 1)
        guard let incrementalRecord = incremental.records.first else { return }
        XCTAssertEqual(incrementalRecord.model, "gpt-x")
        XCTAssertEqual(incrementalRecord.totalTokens, 5)
        XCTAssertFalse(incrementalRecord.id.contains("carried_forward"))
    }

    func testCarriedForwardParticipatesInReconciliationButIsNotImported() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (2, 's1', 1780000010, NULL, 5, 0, 5, 0, 0, 0.01, 'carried_forward', 0);
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let ordinary = try XCTUnwrap(result.records.first(where: { $0.model == "gpt-x" }))
        XCTAssertEqual(ordinary.totalTokens, 30)
        XCTAssertEqual(result.records.filter { $0.model == "goose" }.count, 0)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 30)
    }

    func testSameSecondAndSameTokensRemainDistinctByLedgerId() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (2, 's1', 1780000000, 'gpt-x', 25, 5, 30, 0, 0, 0.01, 'estimated', 0),
          (3, 's1', 1780000000, 'gpt-x', 25, 5, 30, 0, 0, 0.01, 'estimated', 0);
        UPDATE sessions SET accumulated_input_tokens = 80,
                            accumulated_output_tokens = 15,
                            accumulated_total_tokens = 95,
                            accumulated_cost = 0.03;
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let ordinary = result.records.filter { $0.model == "gpt-x" }
        XCTAssertEqual(ordinary.count, 3)
        XCTAssertEqual(Set(ordinary.map(\.id)).count, 3)
        XCTAssertEqual(ordinary.map(\.timestamp), Array(repeating: Date(timeIntervalSince1970: 1_780_000_000), count: 3))
    }

    func testInputIncludesCacheAndIsSplitIntoUnifiedFields() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        UPDATE sessions SET accumulated_input_tokens = 130,
                            accumulated_output_tokens = 5,
                            accumulated_total_tokens = 135,
                            accumulated_cache_read_tokens = 12,
                            accumulated_cache_write_tokens = 3,
                            accumulated_cost = 0.01;
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let ordinary = try XCTUnwrap(result.records.first(where: { $0.model == "gpt-x" }))
        XCTAssertEqual(ordinary.inputTokens, 13)
        XCTAssertEqual(ordinary.outputTokens, 5)
        XCTAssertEqual(ordinary.cacheReadTokens, 10)
        XCTAssertEqual(ordinary.cacheWriteTokens, 2)
        XCTAssertEqual(ordinary.totalTokens, 30)
    }

    func testParentChildTreeReconcilesEachSessionIndependently() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        INSERT INTO sessions
          (id, parent_session_id, provider_name, accumulated_input_tokens, accumulated_output_tokens,
           accumulated_total_tokens, accumulated_cache_read_tokens, accumulated_cache_write_tokens,
           accumulated_cost, created_at, updated_at)
        VALUES
          ('child', 's1', 'openai', 20, 0, 20, 0, 0, 0.01, 1780000100, 1780000100),
          ('grandchild', 'child', 'openai', 10, 0, 10, 0, 0, 0.005, 1780000200, 1780000200);
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (2, 'child', 1780000100, 'child-model', 20, 0, 20, 0, 0, 0.01, 'estimated', 0),
          (3, 'grandchild', 1780000200, 'grandchild-model', 10, 0, 10, 0, 0, 0.005, 'estimated', 0);
        UPDATE sessions SET accumulated_input_tokens = 100,
                            accumulated_output_tokens = 0,
                            accumulated_total_tokens = 100,
                            accumulated_cost = 0.03
        WHERE id = 's1';
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let baselines = result.records.filter { $0.model == "goose" }
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(baselines.first?.sessionKey, "s1")
        XCTAssertEqual(baselines.first?.totalTokens, 70)
        XCTAssertEqual(result.records.filter { $0.model == "child-model" }.first?.sessionKey, "child")
        XCTAssertEqual(result.records.filter { $0.model == "grandchild-model" }.first?.sessionKey, "grandchild")
        let ordinaryTotal = result.records.filter { $0.model != "goose" }.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(ordinaryTotal, 60)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 130)
    }

    func testUnknownAndPartiallyNullLedgerUsage() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (2, 's1', 1780000010, 'unknown-model', NULL, NULL, NULL, NULL, NULL, 0.001, 'estimated', 0),
          (3, 's1', 1780000020, 'partial-model', NULL, 5, 5, NULL, NULL, 0.002, 'estimated', 0);
        UPDATE sessions SET accumulated_input_tokens = 35,
                            accumulated_output_tokens = 10,
                            accumulated_total_tokens = 40,
                            accumulated_cost = 0.03;
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        XCTAssertEqual(result.records.filter { $0.model == "unknown-model" }.count, 0)
        let partial = try XCTUnwrap(result.records.first(where: { $0.model == "partial-model" }))
        XCTAssertEqual(partial.inputTokens, 0)
        XCTAssertEqual(partial.outputTokens, 5)
        XCTAssertEqual(partial.totalTokens, 5)
    }

    func testLegacyBaselineUsesSessionDateFallback() async throws {
        let databaseURL = try makeFixture()
        try execute("""
        DELETE FROM usage_ledger;
        UPDATE sessions SET accumulated_input_tokens = 10,
                            accumulated_output_tokens = 0,
                            accumulated_total_tokens = 10,
                            accumulated_cost = 0.01,
                            created_at = NULL,
                            updated_at = 1780000999;
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let baseline = try XCTUnwrap(result.records.first(where: { $0.model == "goose" }))
        XCTAssertEqual(baseline.timestamp, Date(timeIntervalSince1970: 1_780_000_999))
        XCTAssertNotEqual(baseline.timestamp, Date(timeIntervalSince1970: 0))
    }

    func testLegacySchemaWithoutParentOrSessionDatesFallsBackSafely() async throws {
        let databaseURL = tempDirectory.appendingPathComponent("legacy.db")
        try execute(Self.legacySchema, on: databaseURL)
        try execute("""
        INSERT INTO sessions (id, provider_name, accumulated_input_tokens, accumulated_output_tokens,
                              accumulated_total_tokens, accumulated_cache_read_tokens,
                              accumulated_cache_write_tokens, accumulated_cost)
        VALUES ('legacy', 'openai', 4, 0, 4, 0, 0, 0.01);
        """, on: databaseURL)

        let result = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let baseline = try XCTUnwrap(result.records.first)
        XCTAssertEqual(baseline.totalTokens, 4)
        XCTAssertNotEqual(baseline.timestamp, Date(timeIntervalSince1970: 0))
    }

    func testSyntheticBaselineIsDeterministicAndDatabaseInsertIsIdempotent() async throws {
        let databaseURL = try makeFixture()
        let storeURL = tempDirectory.appendingPathComponent("usage.db")
        let database = try DatabaseManager(path: storeURL.path)
        let adapter = GooseAdapter()

        let firstFetch = try await adapter.fetchIncrementalRecords(from: databaseURL, since: nil)
        let first = try database.insertRecords(
            firstFetch.records,
            updateCursorFor: adapter.sourceId,
            cursor: firstFetch.newCursor
        )
        let secondFetch = try await adapter.fetchIncrementalRecords(from: databaseURL, since: firstFetch.newCursor)
        let second = try database.insertRecords(
            secondFetch.records,
            updateCursorFor: adapter.sourceId,
            cursor: secondFetch.newCursor
        )
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(try database.fetchTotalRecordCount(), 2)
    }

    func testUnsupportedSchemaIsRejected() async throws {
        let databaseURL = tempDirectory.appendingPathComponent("unsupported.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let sql = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, provider_name TEXT);
        CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY, session_id TEXT);
        """
        sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)

        do {
            _ = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
            XCTFail("Expected unsupported schema error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "GooseAdapter")
            XCTAssertTrue(error.localizedDescription.contains("Unsupported Goose schema"))
        }
    }

    func testIdentityChangesWhenDatabaseFileIsReplaced() async throws {
        let databaseURL = try makeFixture()
        let adapter = GooseAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: databaseURL, since: nil)
        let replacementURL = tempDirectory.appendingPathComponent("replacement.db")
        try FileManager.default.copyItem(at: databaseURL, to: replacementURL)
        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.moveItem(at: replacementURL, to: databaseURL)
        let replaced = try await adapter.fetchIncrementalRecords(from: databaseURL, since: first.newCursor)

        guard case .databaseIdentity(let firstIdentity, _) = first.newCursor,
              case .databaseIdentity(let secondIdentity, _) = replaced.newCursor else {
            return XCTFail("Expected database identity cursors")
        }
        XCTAssertNotEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(replaced.records.count, 2)
    }

    func testMaximumIdRegressionRequestsCoordinatorCutover() async throws {
        let databaseURL = try makeFixture()
        let adapter = GooseAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: databaseURL, since: nil)
        try execute("INSERT INTO usage_ledger VALUES (2, 's1', 1780000001, 'gpt-x', 1, 0, 1, 0, 0, 0.001, 'estimated', 0);", on: databaseURL)
        let advanced = try await adapter.fetchIncrementalRecords(from: databaseURL, since: first.newCursor)
        try execute("DELETE FROM usage_ledger WHERE id = 2;", on: databaseURL)
        let regressed = try await adapter.fetchIncrementalRecords(from: databaseURL, since: advanced.newCursor)
        XCTAssertEqual(regressed.records, [])
        XCTAssertEqual(regressed.newCursor, .rowId(1))
    }

    func testReadOnlyConnectionLeavesWALAndMainDatabaseUnchanged() async throws {
        let databaseURL = try makeFixture()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK)
        sqlite3_exec(writer, Self.insertLedger, nil, nil, nil)
        let mainBefore = try Data(contentsOf: databaseURL)
        let walBefore = try? Data(contentsOf: URL(fileURLWithPath: databaseURL.path + "-wal"))

        _ = try await GooseAdapter().fetchIncrementalRecords(from: databaseURL, since: nil)
        let mainAfter = try Data(contentsOf: databaseURL)
        let walAfter = try? Data(contentsOf: URL(fileURLWithPath: databaseURL.path + "-wal"))
        XCTAssertEqual(mainAfter, mainBefore)
        XCTAssertEqual(walAfter, walBefore)
        sqlite3_close(writer)
    }

    func testDefaultEnvironmentPathsAndDirectoryInput() async throws {
        let root = tempDirectory.appendingPathComponent("goose-root")
        let sessions = root.appendingPathComponent("data/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let databaseURL = sessions.appendingPathComponent("sessions.db")
        _ = try makeFixture(at: databaseURL)

        XCTAssertEqual(
            GooseAdapter.databaseURL(environment: ["GOOSE_PATH_ROOT": root.path]),
            databaseURL
        )
        XCTAssertEqual(GooseAdapter.sessionsRoot(environment: ["GOOSE_PATH_ROOT": root.path]).path, sessions.path)
        XCTAssertEqual(GooseAdapter.databaseURL(environment: ["GOOSE_PATH_ROOT": "relative/root"]).path,
                       (GooseAdapter().defaultPath as NSString).expandingTildeInPath)

        let directoryResult = try await GooseAdapter().fetchIncrementalRecords(from: sessions, since: nil)
        XCTAssertEqual(directoryResult.records.count, 2)
    }

    func testMetadataAndRegistration() {
        let adapter = GooseAdapter()
        XCTAssertEqual(adapter.sourceId, "goose")
        XCTAssertEqual(adapter.displayName, "Goose")
        XCTAssertEqual(adapter.defaultPath, "~/Library/Application Support/Block/goose/sessions/sessions.db")
        XCTAssertTrue(AdapterCatalog.defaults.contains(where: { $0 is GooseAdapter }))
        XCTAssertEqual(AgentFilterBarView.displayName(for: "goose"), "Goose")
    }

    // MARK: - Fixtures

    private func makeFixture(at databaseURL: URL? = nil) throws -> URL {
        let url = databaseURL ?? tempDirectory.appendingPathComponent("sessions.db")
        try execute(Self.schema, on: url)
        try execute("""
        INSERT INTO sessions
          (id, parent_session_id, provider_name, accumulated_input_tokens, accumulated_output_tokens,
           accumulated_total_tokens, accumulated_cache_read_tokens, accumulated_cache_write_tokens,
           accumulated_cost, created_at, updated_at)
        VALUES
          ('s1', NULL, 'openai', 30, 5, 35, 0, 0, 0.02, 1780000000, 1780000000);
        INSERT INTO usage_ledger
          (id, session_id, created_timestamp, model, input_tokens, output_tokens,
           total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
        VALUES
          (1, 's1', 1780000000, 'gpt-x', 25, 5, 30, 10, 2, 0.01, 'estimated', 0);
        """, on: url)
        return url
    }

    private func execute(_ sql: String, on databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            XCTFail("Unable to create fixture database")
            return
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    private static let schema = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        parent_session_id TEXT,
        provider_name TEXT,
        accumulated_input_tokens INTEGER,
        accumulated_output_tokens INTEGER,
        accumulated_total_tokens INTEGER,
        accumulated_cache_read_tokens INTEGER,
        accumulated_cache_write_tokens INTEGER,
        accumulated_cost REAL,
        created_at INTEGER,
        updated_at INTEGER
    );
    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL
    );
    CREATE TABLE usage_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        created_timestamp INTEGER NOT NULL,
        model TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        total_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_write_tokens INTEGER,
        cost REAL,
        cost_source TEXT,
        is_compaction INTEGER DEFAULT 0
    );
    """

    private static let legacySchema = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        provider_name TEXT,
        accumulated_input_tokens INTEGER,
        accumulated_output_tokens INTEGER,
        accumulated_total_tokens INTEGER,
        accumulated_cache_read_tokens INTEGER,
        accumulated_cache_write_tokens INTEGER,
        accumulated_cost REAL
    );
    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL
    );
    CREATE TABLE usage_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        created_timestamp INTEGER NOT NULL,
        model TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        total_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_write_tokens INTEGER,
        cost REAL,
        cost_source TEXT,
        is_compaction INTEGER DEFAULT 0
    );
    """

    private static let insertLedger = """
    INSERT INTO usage_ledger
      (id, session_id, created_timestamp, model, input_tokens, output_tokens,
       total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction)
    VALUES (2, 's1', 1780000001, 'gpt-x', 5, 1, 6, 0, 0, 0.002, 'estimated', 0);
    """
}
