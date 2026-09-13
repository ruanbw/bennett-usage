import XCTest
@testable import BennettUsageCore

final class AdditionalAdaptersTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testClaudeAndCodexAdaptersConformToProtocol() {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        XCTAssertEqual(claude.sourceId, "claude")
        XCTAssertEqual(codex.sourceId, "codex")
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(codex.displayName, "OpenAI Codex")
        XCTAssertEqual(claude.brandColorHex, "#D97706")
        XCTAssertEqual(codex.brandColorHex, "#10A37F")
        XCTAssertEqual(claude.sfSymbolIcon, "brain.head.profile")
        XCTAssertEqual(codex.sfSymbolIcon, "chevron.left.forwardslash.chevron.right")
    }

    func testDefaultPathDetection() {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        // Should return URL if exists or nil, must not crash
        _ = claude.detectDefaultPath()
        _ = codex.detectDefaultPath()
    }

    func testClaudeParsesTranscriptWithMessageIdDedupe() async throws {
        // One API turn fanned out into two assistant lines repeating the same
        // usage: only one record may survive, keyed by message.id.
        let projectDir = tempDir.appendingPathComponent("-Users-test-app")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileUrl = projectDir.appendingPathComponent("session-uuid.jsonl")
        let lines = """
        {"type":"user","uuid":"u1","timestamp":"2026-09-12T01:00:00.000Z","sessionId":"sess-1","cwd":"/Users/test/app","message":{"role":"user","content":"hi"}}\n
        {"type":"assistant","uuid":"a1","timestamp":"2026-09-12T01:00:01.000Z","sessionId":"sess-1","cwd":"/Users/test/app","message":{"id":"msg_1","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":50}}}\n
        {"type":"assistant","uuid":"a2","timestamp":"2026-09-12T01:00:02.000Z","sessionId":"sess-1","cwd":"/Users/test/app","message":{"id":"msg_1","model":"claude-sonnet-4-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":50}}}\n
        """
        try lines.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = ClaudeAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "claude_msg_1")
        XCTAssertEqual(record.sourceId, "claude")
        XCTAssertEqual(record.inputTokens, 100)
        XCTAssertEqual(record.outputTokens, 20)
        XCTAssertEqual(record.cacheReadTokens, 500)
        XCTAssertEqual(record.cacheWriteTokens, 50)
        XCTAssertEqual(record.model, "claude-sonnet-4-5")
        XCTAssertEqual(record.sessionKey, "sess-1")
        XCTAssertEqual(record.projectFolder, "/Users/test/app")

        // Second fetch with cursor returns nothing new.
        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testCodexParsesTokenCountEvents() async throws {
        let dayDir = tempDir.appendingPathComponent("2026/09/12", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let fileUrl = dayDir.appendingPathComponent("rollout-2026-09-12T01-00-00-019eaadc-d12d-7f33-84e8-cd56bba38544.jsonl")
        let lines = """
        {"timestamp":"2026-09-12T01:00:00.000Z","type":"session_meta","payload":{"id":"019eaadc-d12d-7f33-84e8-cd56bba38544","model":"gpt-5"}}\n
        {"timestamp":"2026-09-12T01:00:05.000Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5","info":{"total_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"total_tokens":15150},"last_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"reasoning_output_tokens":30,"total_tokens":15150},"model_context_window":272000}}}\n
        """
        try lines.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.sourceId, "codex")
        // input_tokens includes cached: split, don't double count.
        XCTAssertEqual(record.inputTokens, 1000)
        XCTAssertEqual(record.cacheReadTokens, 14000)
        XCTAssertEqual(record.outputTokens, 150)
        XCTAssertEqual(record.totalTokens, 15150)
        XCTAssertEqual(record.model, "gpt-5")

        let again = try await adapter.fetchIncrementalRecords(from: tempDir, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testCodexSkipsRateLimitRebroadcastWithSameTotalTokens() async throws {
        let dayDir = tempDir.appendingPathComponent("2026/09/12", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let fileUrl = dayDir.appendingPathComponent("rollout-2026-09-12T01-00-00-019eaadc-d12d-7f33-84e8-cd56bba38544.jsonl")
        let lines = """
        {"timestamp":"2026-09-12T01:00:00.000Z","type":"session_meta","payload":{"id":"019eaadc-d12d-7f33-84e8-cd56bba38544","model":"gpt-5"}}\n
        {"timestamp":"2026-09-12T01:00:05.000Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5","info":{"total_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"total_tokens":15150},"last_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"reasoning_output_tokens":30,"total_tokens":15150},"model_context_window":272000}}}\n
        {"timestamp":"2026-09-12T01:00:06.000Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5","info":{"total_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"total_tokens":15150},"last_token_usage":{"input_tokens":15000,"cached_input_tokens":14000,"output_tokens":150,"reasoning_output_tokens":30,"total_tokens":15150},"model_context_window":272000}}}\n
        """
        try lines.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.sourceId, "codex")
        XCTAssertEqual(record.inputTokens, 1000)
        XCTAssertEqual(record.cacheReadTokens, 14000)
        XCTAssertEqual(record.outputTokens, 150)
        XCTAssertEqual(record.totalTokens, 15150)
    }
}
