import XCTest
@testable import BennettUsageCore

/// Cline's standalone runtime ("Cline Code" / `cline` CLI) keeps a canonical
/// session store under `<cline dir>/data/sessions`, separate from the VSCode
/// extension history that `RooCodeAdapter` reads.
final class ClineAdapterTests: XCTestCase {
    var tempDir: URL!
    var sessionsRoot: URL!
    let adapter = ClineAdapter()

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessionsRoot = tempDir.appendingPathComponent("data/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    @discardableResult
    private func writeSession(id: String, manifest: String? = nil, transcript: String? = nil) throws -> URL {
        let dir = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        }
        if let transcript {
            try transcript.write(to: dir.appendingPathComponent("\(id).messages.json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func manifestJSON(
        model: String = "cline-free/deepseek-v4.1-flash",
        provider: String = "cline",
        workspaceRoot: String = "/Users/test/cline-proj",
        cwd: String = "/Users/test/cline-proj",
        usageJSON: String? = nil
    ) -> String {
        let usage = usageJSON
            ?? #"{"inputTokens":999,"outputTokens":999,"cacheReadTokens":999,"cacheWriteTokens":999,"totalCost":0}"#
        return """
        {"version":1,"session_id":"sid","started_at":"2026-09-15T17:02:49.714Z","status":"idle",\
        "provider":"\(provider)","model":"\(model)","cwd":"\(cwd)","workspace_root":"\(workspaceRoot)",\
        "metadata":{"provider":"\(provider)","model":"\(model)","usage":\(usage)}}
        """
    }

    /// Two assistant turns (the second one cache-heavy) plus a user message
    /// that must not produce a record.
    private func transcriptJSON(sessionId: String) -> String {
        """
        {"version":1,"updated_at":"2026-09-15T17:04:27.452Z","sessionId":"\(sessionId)","messages":[\
        {"id":"msg_user","role":"user","content":[{"type":"text","text":"hi"}],"ts":1789491769918},\
        {"id":"msg_1","role":"assistant","content":[],"ts":1789491775858,\
        "modelInfo":{"id":"cline-free/deepseek-v4.1-flash","provider":"cline","family":"deepseek-flash"},\
        "metrics":{"inputTokens":6740,"outputTokens":206,"cacheReadTokens":0,"cacheWriteTokens":0}},\
        {"id":"msg_2","role":"assistant","content":[],"ts":1789491786708,\
        "modelInfo":{"id":"anthropic/claude-sonnet-4.5","provider":"anthropic","family":"claude"},\
        "metrics":{"inputTokens":7642,"outputTokens":173,"cacheReadTokens":64,"cacheWriteTokens":20}}\
        ]}
        """
    }

    /// Appends `body` to an app event stream. `terminated` mirrors real writes
    /// (each event line ends with a newline); the partial-line test turns it
    /// off to model a line still being flushed.
    @discardableResult
    private func writeStream(sessionId: String, app: String = "kanban", terminated: Bool = true, body: String) throws -> URL {
        let dir = tempDir.appendingPathComponent("apps/\(app)/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionId).jsonl")
        let payload = terminated ? body + "\n" : body
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(payload.utf8))
        } else {
            try payload.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    // MARK: - Metadata

    func testMetadataAndRegistration() {
        XCTAssertEqual(adapter.sourceId, "cline")
        XCTAssertEqual(adapter.displayName, "Cline")
        XCTAssertEqual(adapter.defaultPath, "~/.cline/data/sessions")
        XCTAssertFalse(adapter.isSyncStub)
        XCTAssertEqual(AgentFilterBarView.displayName(for: "cline"), "Cline")
        // Agent Health must list Cline even when the shared registry is empty.
        XCTAssertTrue(MetricsAggregator.builtInAdapters().contains { $0.sourceId == "cline" })
        // Detection must never crash.
        _ = adapter.detectDefaultPath()
    }

    // MARK: - Canonical transcript

    func testParsesPerMessageMetricsFromTranscript() async throws {
        try writeSession(id: "session_a", manifest: manifestJSON(), transcript: transcriptJSON(sessionId: "session_a"))

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)

        let first = result.records[0]
        XCTAssertEqual(first.id, "cline_session_a_msg_1")
        XCTAssertEqual(first.sourceId, "cline")
        XCTAssertEqual(first.sessionKey, "session_a")
        XCTAssertEqual(first.model, "cline-free/deepseek-v4.1-flash")
        XCTAssertEqual(first.provider, "cline")
        XCTAssertEqual(first.projectFolder, "/Users/test/cline-proj")
        XCTAssertEqual(first.inputTokens, 6740)
        XCTAssertEqual(first.outputTokens, 206)
        XCTAssertEqual(first.cacheReadTokens, 0)
        XCTAssertEqual(first.cacheWriteTokens, 0)
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, 1789491775.858, accuracy: 0.001)

        let second = result.records[1]
        XCTAssertEqual(second.id, "cline_session_a_msg_2")
        XCTAssertEqual(second.model, "anthropic/claude-sonnet-4.5")
        XCTAssertEqual(second.provider, "anthropic")
        XCTAssertEqual(second.inputTokens, 7642)
        XCTAssertEqual(second.cacheReadTokens, 64)
        XCTAssertEqual(second.cacheWriteTokens, 20)

        // Unchanged snapshot: the size-keyed cursor makes the next pass a no-op.
        let again = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testTranscriptRewriteEmitsAppendedTurnsWithStableIds() async throws {
        try writeSession(id: "session_a", manifest: manifestJSON(), transcript: transcriptJSON(sessionId: "session_a"))
        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(first.records.count, 2)

        let grown = """
        {"version":1,"sessionId":"session_a","messages":[\
        {"id":"msg_1","role":"assistant","content":[],"ts":1789491775858,\
        "modelInfo":{"id":"cline-free/deepseek-v4.1-flash","provider":"cline"},"metrics":{"inputTokens":6740,"outputTokens":206}},\
        {"id":"msg_2","role":"assistant","content":[],"ts":1789491786708,\
        "modelInfo":{"id":"cline-free/deepseek-v4.1-flash","provider":"cline"},"metrics":{"inputTokens":7642,"outputTokens":173}},\
        {"id":"msg_3","role":"assistant","content":[],"ts":1789491795358,\
        "modelInfo":{"id":"cline-free/deepseek-v4.1-flash","provider":"cline"},\
        "metrics":{"inputTokens":16186,"outputTokens":225,"cacheReadTokens":10060,"cacheWriteTokens":0}}\
        ]}
        """
        try writeSession(id: "session_a", manifest: manifestJSON(), transcript: grown)

        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        // The file is rewritten wholesale, so the snapshot is re-read; the
        // stable message-id-derived record ids let the database drop the old
        // turns with INSERT OR IGNORE.
        XCTAssertEqual(second.records.map(\.id), [
            "cline_session_a_msg_1", "cline_session_a_msg_2", "cline_session_a_msg_3",
        ])
        XCTAssertEqual(second.records.last?.cacheReadTokens, 10060)
    }

    func testIgnoresZeroUsageAndTranscriptWithoutMetrics() async throws {
        let zeroUsage = """
        {"version":1,"messages":[\
        {"id":"msg_1","role":"assistant","ts":1789491775858,\
        "modelInfo":{"id":"m","provider":"cline"},"metrics":{"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}},\
        {"id":"msg_2","role":"user","ts":1789491769918}\
        ]}
        """
        try writeSession(id: "session_zero", manifest: manifestJSON(), transcript: zeroUsage)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertTrue(result.records.isEmpty)

        // Fast-reject path: a transcript without the `metrics` key at all.
        try writeSession(id: "session_plain", manifest: manifestJSON(), transcript: #"{"version":1,"messages":[{"id":"m","role":"user"}]}"#)
        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: result.newCursor)
        XCTAssertTrue(second.records.isEmpty)
    }

    func testFilesystemRootIsNotRecordedAsProject() async throws {
        try writeSession(
            id: "session_root",
            manifest: manifestJSON(workspaceRoot: "/", cwd: "/"),
            transcript: transcriptJSON(sessionId: "session_root")
        )

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertNil(result.records[0].projectFolder)
    }

    // MARK: - Manifest aggregate

    func testManifestAggregateUsedOnlyWhenTranscriptIsMissing() async throws {
        try writeSession(
            id: "session_b",
            manifest: manifestJSON(
                model: "openrouter/anthropic/claude-sonnet-4.5",
                provider: "openrouter",
                usageJSON: #"{"inputTokens":1000,"outputTokens":200,"cacheReadTokens":50,"cacheWriteTokens":10,"totalCost":0}"#
            )
        )

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.id, "cline_session_b_aggregate")
        XCTAssertEqual(record.model, "openrouter/anthropic/claude-sonnet-4.5")
        XCTAssertEqual(record.provider, "openrouter")
        XCTAssertEqual(record.projectFolder, "/Users/test/cline-proj")
        XCTAssertEqual(record.inputTokens, 1000)
        XCTAssertEqual(record.outputTokens, 200)
        XCTAssertEqual(record.cacheReadTokens, 50)
        XCTAssertEqual(record.cacheWriteTokens, 10)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, 1789491769.714, accuracy: 0.001)

        let again = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: result.newCursor)
        XCTAssertEqual(again.records.count, 0)
    }

    func testTranscriptSuppressesManifestAggregate() async throws {
        // The manifest aggregate mirrors the transcript; with both present only
        // the per-message records may be ingested, never both.
        try writeSession(
            id: "session_c",
            manifest: manifestJSON(usageJSON: #"{"inputTokens":14382,"outputTokens":379,"cacheReadTokens":64,"cacheWriteTokens":20}"#),
            transcript: transcriptJSON(sessionId: "session_c")
        )

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertFalse(result.records.contains { $0.id.hasSuffix("_aggregate") })
    }

    // MARK: - Per-app event stream

    func testAppStreamParsesPerRequestUsageIncrementally() async throws {
        let stream = """
        {"ts":1789491774314,"stream":"chat_reasoning","chunk":"{\\"text\\":\\"The\\"}"}
        {"ts":1789491775858,"stream":"chat_usage","chunk":"{\\"inputTokens\\":6740,\\"outputTokens\\":206,\\"cacheReadTokens\\":0,\\"cacheWriteTokens\\":0,\\"cost\\":0,\\"totalInputTokens\\":6740,\\"totalOutputTokens\\":206,\\"totalCost\\":0}"}
        {"ts":1789491786708,"stream":"chat_usage","chunk":"{\\"inputTokens\\":7642,\\"outputTokens\\":173,\\"cacheReadTokens\\":64,\\"cacheWriteTokens\\":0,\\"cost\\":0,\\"totalInputTokens\\":14382,\\"totalOutputTokens\\":379,\\"totalCost\\":0}"}
        """
        try writeStream(sessionId: "session_stream", body: stream)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records[0].id.hasPrefix("cline_session_stream_req_"))
        XCTAssertEqual(result.records[0].inputTokens, 6740)
        XCTAssertEqual(result.records[0].outputTokens, 206)
        // Running totals must never be mistaken for the per-request values.
        XCTAssertEqual(result.records[1].inputTokens, 7642)
        XCTAssertEqual(result.records[1].cacheReadTokens, 64)
        XCTAssertEqual(result.records[1].timestamp.timeIntervalSince1970, 1789491786.708, accuracy: 0.001)

        let appended = """
        {"ts":1789491790367,"stream":"chat_usage","chunk":"{\\"inputTokens\\":10189,\\"outputTokens\\":337,\\"cacheReadTokens\\":64,\\"cacheWriteTokens\\":0,\\"cost\\":0,\\"totalInputTokens\\":24571,\\"totalOutputTokens\\":716,\\"totalCost\\":0}"}
        """
        try writeStream(sessionId: "session_stream", body: appended)

        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: result.newCursor)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertEqual(second.records[0].inputTokens, 10189)
        XCTAssertEqual(second.records[0].outputTokens, 337)

        let third = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: second.newCursor)
        XCTAssertEqual(third.records.count, 0)
    }

    func testAppStreamSkippedForSessionsInCanonicalStore() async throws {
        try writeSession(id: "session_a", manifest: manifestJSON(), transcript: transcriptJSON(sessionId: "session_a"))
        try writeStream(
            sessionId: "session_a",
            body: #"{"ts":1789491775858,"stream":"chat_usage","chunk":"{\"inputTokens\":6740,\"outputTokens\":206}"}"#
        )

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { !$0.id.contains("_req_") })
    }

    func testPartialStreamLineIsRereadOnNextPass() async throws {
        // A trailing line without a newline is still being written: it must not
        // be consumed, then read once complete.
        let complete = #"{"ts":1789491775858,"stream":"chat_usage","chunk":"{\"inputTokens\":6740,\"outputTokens\":206}"}"# + "\n"
        try writeStream(
            sessionId: "session_partial",
            terminated: false,
            body: complete + #"{"ts":1789491786708,"stream":"chat_us"#
        )

        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records[0].inputTokens, 6740)

        try writeStream(
            sessionId: "session_partial",
            body: #"age","chunk":"{\"inputTokens\":7642,\"outputTokens\":173}"}"#
        )
        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertEqual(second.records[0].inputTokens, 7642)
    }

    // MARK: - Housekeeping

    func testOffsetEntriesForDeletedSessionsAreDropped() async throws {
        try writeSession(id: "session_gone", manifest: manifestJSON(), transcript: transcriptJSON(sessionId: "session_gone"))
        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(first.records.count, 2)

        try FileManager.default.removeItem(at: sessionsRoot.appendingPathComponent("session_gone"))
        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertTrue(second.records.isEmpty)
        guard case .fileOffsets(let offsets) = second.newCursor else {
            return XCTFail("expected a file-offsets cursor")
        }
        XCTAssertTrue(offsets.isEmpty)
    }
}
