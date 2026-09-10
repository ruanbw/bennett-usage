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

    func testOmpAdapterMetadata() {
        let adapter = OmpAdapter()
        XCTAssertEqual(adapter.sourceId, "omp")
        XCTAssertEqual(adapter.displayName, "Oh My Pi")
        XCTAssertEqual(adapter.brandColorHex, "#3B82F6")
        XCTAssertEqual(adapter.sfSymbolIcon, "terminal.fill")
    }

    func testOmpAdapterDetectDefaultPath() {
        let adapter = OmpAdapter()
        // Just verify call completes without crashing
        _ = adapter.detectDefaultPath()
    }

    func testOmpAdapterDatabaseOpenFailure() async {
        let adapter = OmpAdapter()
        let missingUrl = tempDir.appendingPathComponent("nonexistent/stats.db")
        do {
            _ = try await adapter.fetchIncrementalRecords(from: missingUrl, since: nil)
            XCTFail("Expected fetch to fail for nonexistent path")
        } catch {
            // Expected failure
        }
    }
}
