import XCTest
import SQLite3
@testable import BennettUsageCore

final class NewAdaptersTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Metadata

    func testNewAdapterMetadata() {
        XCTAssertEqual(OpenCodeAdapter().sourceId, "opencode")
        XCTAssertEqual(OpenCodeAdapter().displayName, "OpenCode")
        XCTAssertEqual(RooCodeAdapter().sourceId, "roo")
        XCTAssertEqual(QwenCodeAdapter().sourceId, "qwen")
        XCTAssertEqual(QwenCodeAdapter().displayName, "Qwen Code")
        XCTAssertEqual(CopilotAdapter().sourceId, "copilot")
        XCTAssertEqual(CursorAdapter().sourceId, "cursor")
        XCTAssertEqual(TraeAdapter().sourceId, "trae")
        // Cloud-billed tools are detection-only stubs.
        XCTAssertTrue(CopilotAdapter().isSyncStub)
        XCTAssertTrue(CursorAdapter().isSyncStub)
        XCTAssertTrue(TraeAdapter().isSyncStub)
        XCTAssertFalse(OpenCodeAdapter().isSyncStub)
        XCTAssertFalse(RooCodeAdapter().isSyncStub)
        XCTAssertFalse(QwenCodeAdapter().isSyncStub)
        // Detection must never crash.
        _ = OpenCodeAdapter().detectDefaultPath()
        _ = RooCodeAdapter().detectDefaultPath()
        _ = QwenCodeAdapter().detectDefaultPath()
        _ = CopilotAdapter().detectDefaultPath()
        _ = CursorAdapter().detectDefaultPath()
        _ = TraeAdapter().detectDefaultPath()
    }

    func testStubAdaptersReturnEmptyWithTimestampCursor() async throws {
        for adapter: any AgentSourceAdapter in [CopilotAdapter(), CursorAdapter(), TraeAdapter()] {
            let (records, cursor) = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
            XCTAssertTrue(records.isEmpty, "\(adapter.sourceId) should return no records")
            if case .timestamp = cursor { /* expected */ }
            else { XCTFail("\(adapter.sourceId) should return a timestamp cursor") }
        }
    }

    // MARK: - Qwen (Gemini-fork layout)

    func testQwenParsesSessionJsonl() async throws {
        let chats = tempDir.appendingPathComponent("tmp/abc123/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let fileUrl = chats.appendingPathComponent("session-xyz.jsonl")
        let lines = """
        {"sessionId":"sess-q","directories":["/Users/test/proj"]}\n
        {"message":{"type":"qwen","id":"m1","model":"qwen3-coder-plus","timestamp":"2026-09-12T02:00:00.000Z","tokens":{"input":1100,"output":200,"cached":1000,"thoughts":50,"total":1350}}}\n
        """
        try lines.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = QwenCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "qwen_sess-q_m1")
        XCTAssertEqual(record.sourceId, "qwen")
        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.outputTokens, 250)
        XCTAssertEqual(record.cacheReadTokens, 1000)
        XCTAssertEqual(record.model, "qwen3-coder-plus")
        XCTAssertEqual(record.sessionKey, "sess-q")
        XCTAssertEqual(record.projectFolder, "/Users/test/proj")

        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testQwenParsesUUIDSessionJsonl() async throws {
        let chats = tempDir.appendingPathComponent("tmp/abc123/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let fileUrl = chats.appendingPathComponent("407a66c9-1234-5678-9abc-def012345678.jsonl")
        let lines = """
        {"sessionId":"407a66c9-1234-5678-9abc-def012345678","directories":["/Users/test/proj"]}\n
        {"message":{"type":"qwen","id":"m1","model":"qwen3-coder-plus","timestamp":"2026-09-12T02:00:00.000Z","tokens":{"input":1100,"output":200,"cached":1000,"thoughts":50,"total":1350}}}\n
        """
        try lines.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = QwenCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "qwen_407a66c9-1234-5678-9abc-def012345678_m1")
        XCTAssertEqual(record.sourceId, "qwen")
        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.outputTokens, 250)
        XCTAssertEqual(record.cacheReadTokens, 1000)
        XCTAssertEqual(record.model, "qwen3-coder-plus")
        XCTAssertEqual(record.sessionKey, "407a66c9-1234-5678-9abc-def012345678")
        XCTAssertEqual(record.projectFolder, "/Users/test/proj")

        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    // MARK: - Roo / Cline

    func testRooParsesApiConversationHistory() async throws {
        let taskDir = tempDir.appendingPathComponent("task-123", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let history = """
        [{"ts":1789000000000,"type":"say","say":"text","text":"hello","tokensIn":800,"tokensOut":120,"cacheWrites":200,"cacheReads":600}]
        """
        try history.write(to: taskDir.appendingPathComponent("api_conversation_history.json"),
                          atomically: true, encoding: .utf8)

        let adapter = RooCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "roo_task-123_0")
        XCTAssertEqual(record.sourceId, "roo")
        XCTAssertEqual(record.inputTokens, 800)
        XCTAssertEqual(record.outputTokens, 120)
        XCTAssertEqual(record.cacheWriteTokens, 200)
        XCTAssertEqual(record.cacheReadTokens, 600)
        XCTAssertEqual(record.sessionKey, "task-123")

        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testRooParsesNestedAnthropicUsage() async throws {
        let taskDir = tempDir.appendingPathComponent("task-anthropic", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let history = """
        [{"role":"assistant","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":50}}]
        """
        try history.write(to: taskDir.appendingPathComponent("api_conversation_history.json"),
                          atomically: true, encoding: .utf8)

        let adapter = RooCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "roo_task-anthropic_0")
        XCTAssertEqual(record.sourceId, "roo")
        XCTAssertEqual(record.inputTokens, 500)
        XCTAssertEqual(record.outputTokens, 100)
        XCTAssertEqual(record.cacheReadTokens, 200)
        XCTAssertEqual(record.cacheWriteTokens, 50)
        XCTAssertEqual(record.sessionKey, "task-anthropic")

        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testRooExtractsProjectFromUiMessagesArray() async throws {
        let taskDir = tempDir.appendingPathComponent("task-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let history = """
        [{"role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]
        """
        try history.write(to: taskDir.appendingPathComponent("api_conversation_history.json"),
                          atomically: true, encoding: .utf8)
        let uiMessages = """
        [{"say":"task","text":"hello","workspace":"/Users/test/roo-project"}]
        """
        try uiMessages.write(to: taskDir.appendingPathComponent("ui_messages.json"),
                             atomically: true, encoding: .utf8)

        let adapter = RooCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].projectFolder, "/Users/test/roo-project")
    }

    // MARK: - OpenCode JSON fallback

    func testOpenCodeParsesLegacyMessageFiles() async throws {
        let msgDir = tempDir.appendingPathComponent("storage/message/sess-oc", isDirectory: true)
        try FileManager.default.createDirectory(at: msgDir, withIntermediateDirectories: true)
        let msg = """
        {"id":"msg_1","sessionID":"sess-oc","role":"assistant","modelID":"claude-sonnet-4-5","directory":"/Users/test/oc","time":{"created":1789000000000},"usage":{"input_tokens":400,"output_tokens":90,"cache_read_input_tokens":3000,"cache_creation_input_tokens":100}}
        """
        try msg.write(to: msgDir.appendingPathComponent("msg_1.json"), atomically: true, encoding: .utf8)
        // A compaction-flavored user message must not produce records.
        let userDir = tempDir.appendingPathComponent("storage/message/sess-oc2", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userMsg = """
        {"id":"msg_2","sessionID":"sess-oc2","role":"user","modelID":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":0}}
        """
        try userMsg.write(to: userDir.appendingPathComponent("msg_2.json"), atomically: true, encoding: .utf8)

        let adapter = OpenCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "opencode_msg_1")
        XCTAssertEqual(record.sourceId, "opencode")
        XCTAssertEqual(record.inputTokens, 400)
        XCTAssertEqual(record.outputTokens, 90)
        XCTAssertEqual(record.cacheReadTokens, 3000)
        XCTAssertEqual(record.cacheWriteTokens, 100)
        XCTAssertEqual(record.model, "claude-sonnet-4-5")
        XCTAssertEqual(record.projectFolder, "/Users/test/oc")
    }

    // MARK: - OpenCode V2 (`session_message` / `session_v2`)

    /// Minimal V2 database: two settled turns, one streaming turn (`msg_a2`
    /// has no `finish` yet) and non-assistant rows that must be ignored.
    @discardableResult
    private func makeOpenCodeV2Database() throws -> URL {
        let dbUrl = tempDir.appendingPathComponent("opencode.db")
        try exec(dbUrl, """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
            seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        INSERT INTO session_v2 (id, directory) VALUES ('ses_v2', '/Users/test/oc-v2');
        INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES
            ('msg_u1', 'ses_v2', 'user', 1, 1789943226000, 1789943226001,
             '{"time":{"created":1789943226000},"text":"hi"}'),
            ('msg_a1', 'ses_v2', 'assistant', 2, 1789943226788, 1789943229947,
             '{"time":{"created":1789943226788,"completed":1789943229946},"agent":"build","model":{"id":"deepseek-v4.1-flash","providerID":"opencode-go"},"finish":"tool-calls","tokens":{"input":7324,"output":130,"reasoning":81,"cache":{"read":7424,"write":100}}}'),
            ('msg_idle', 'ses_v2', 'idle', 3, 1789943229950, 1789943229951,
             '{"time":{"created":1789943229950}}'),
            ('msg_a2', 'ses_v2', 'assistant', 4, 1789943230000, 1789943230500,
             '{"time":{"created":1789943230000,"streamed":1789943230500},"model":{"id":"deepseek-v4.1-flash"}}');
        """)
        return dbUrl
    }

    private func exec(_ dbUrl: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbUrl.path, &db) == SQLITE_OK else {
            throw XCTSkip("could not open \(dbUrl.path)")
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? ""
        sqlite3_free(error)
        XCTAssertEqual(status, SQLITE_OK, message)
    }

    func testOpenCodeV2ParsesSessionMessages() async throws {
        try makeOpenCodeV2Database()

        let adapter = OpenCodeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)

        // Only the finished assistant turn: user, idle and the streaming row
        // never become records.
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "opencode_msg_a1")
        XCTAssertEqual(record.sourceId, "opencode")
        XCTAssertEqual(record.sessionKey, "ses_v2")
        XCTAssertEqual(record.model, "deepseek-v4.1-flash")
        // Project comes from `session_v2.directory` (the payload has none).
        XCTAssertEqual(record.projectFolder, "/Users/test/oc-v2")
        XCTAssertEqual(record.inputTokens, 7324)
        // Reasoning is billed as output and reported separately by OpenCode.
        XCTAssertEqual(record.outputTokens, 130 + 81)
        XCTAssertEqual(record.cacheReadTokens, 7424)
        XCTAssertEqual(record.cacheWriteTokens, 100)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, 1789943226.788, accuracy: 0.001)
    }

    func testOpenCodeV2PicksUpTurnsThatFinishAfterTheFirstSync() async throws {
        let dbUrl = try makeOpenCodeV2Database()
        let adapter = OpenCodeAdapter()

        let first = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(first.records.count, 1)

        // A re-read with the returned cursor must not duplicate anything.
        let second = try await adapter.fetchIncrementalRecords(from: tempDir, since: first.newCursor)
        XCTAssertTrue(second.records.isEmpty)

        // `msg_a2` completes in place (same rowid, now with a finish marker and
        // tokens): the pending-rowid cursor has to surface it.
        try exec(dbUrl, """
        UPDATE session_message SET data =
            '{"time":{"created":1789943230000,"completed":1789943234000},"model":{"id":"deepseek-v4.1-flash"},"finish":"stop","tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":30,"write":0}}}'
        WHERE id = 'msg_a2';
        """)

        let third = try await adapter.fetchIncrementalRecords(from: tempDir, since: second.newCursor)
        XCTAssertEqual(third.records.count, 1)
        XCTAssertEqual(third.records[0].id, "opencode_msg_a2")
        XCTAssertEqual(third.records[0].inputTokens, 10)
        XCTAssertEqual(third.records[0].outputTokens, 25)
        XCTAssertEqual(third.records[0].cacheReadTokens, 30)
    }

    // MARK: - Filter bar names

    func testFilterBarDisplayNamesForNewAgents() {
        XCTAssertEqual(AgentFilterBarView.displayName(for: "opencode"), "OpenCode")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "roo"), "Roo Code · Cline")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "qwen"), "Qwen Code")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "copilot"), "GitHub Copilot")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "cursor"), "Cursor")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "trae"), "Trae")
    }
}
