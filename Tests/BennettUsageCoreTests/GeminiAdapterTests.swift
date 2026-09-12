import XCTest
@testable import BennettUsageCore

final class GeminiAdapterTests: XCTestCase {
    var tempDir: URL!
    var rootDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        rootDir = tempDir.appendingPathComponent("gemini").appendingPathComponent("tmp")
            .appendingPathComponent("abc123").appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSessionFile(name: String, lines: [String]) throws -> URL {
        let url = rootDir.appendingPathComponent(name)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFetchStreamingJsonlRecords() async throws {
        _ = try writeSessionFile(name: "session-2026-09-10T18-13-00-abc.jsonl", lines: [
            #"{"sessionId":"sess-1","projectHash":"abc123","startTime":"2026-09-10T18:13:00Z","lastUpdated":"2026-09-10T18:20:00Z","messages":[],"directories":["/tmp/projX"]}"#,
            #"{"id":"m1","timestamp":"2026-09-10T18:13:21.000Z","type":"user","content":"hi"}"#,
            #"{"id":"m2","timestamp":"2026-09-10T18:13:22.500Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":1000,"output":300,"cached":200,"thoughts":50,"total":1350}}"#,
            #"{"$rewindTo":"m1"}"#,
            #"{"$set":{"summary":"resumed"}}"#,
            #"{"id":"m3","timestamp":"2026-09-10T18:14:00Z","type":"gemini","model":"gemini-2.5-flash","tokens":null}"#,
        ])

        let adapter = GeminiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir.appendingPathComponent("gemini"), since: nil)

        XCTAssertEqual(result.records.count, 1)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.id, "gemini_sess-1_m2")
        XCTAssertEqual(record.sourceId, "gemini")
        XCTAssertEqual(record.model, "gemini-2.5-pro")
        XCTAssertEqual(record.provider, "google")
        XCTAssertEqual(record.sessionKey, "sess-1")
        XCTAssertEqual(record.projectFolder, "/tmp/projX")
        // promptTokenCount (1000) includes cached (200); thoughts (50) count as output.
        XCTAssertEqual(record.inputTokens, 800)
        XCTAssertEqual(record.cacheReadTokens, 200)
        XCTAssertEqual(record.outputTokens, 350)
        XCTAssertEqual(record.totalTokens, 1350)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(record.timestamp, try XCTUnwrap(formatter.date(from: "2026-09-10T18:13:22.500Z")))
    }

    func testFetchLegacySingleJsonSession() async throws {
        let payload = """
        {"sessionId":"legacy-1","projectHash":"abc123","startTime":"2026-09-09T10:00:00Z",
         "lastUpdated":"2026-09-09T10:05:00Z",
         "messages":[
           {"id":"g1","timestamp":"2026-09-09T10:04:59Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":500,"output":100,"total":600}},
           {"id":"u1","timestamp":"2026-09-09T10:04:00Z","type":"user","content":"hello"}
         ]}
        """
        try payload.write(to: rootDir.appendingPathComponent("session-legacy.json"), atomically: true, encoding: .utf8)

        let adapter = GeminiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir.appendingPathComponent("gemini"), since: nil)

        XCTAssertEqual(result.records.count, 1)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.id, "gemini_legacy-1_g1")
        XCTAssertEqual(record.sessionKey, "legacy-1")
        XCTAssertEqual(record.inputTokens, 500)
        XCTAssertEqual(record.outputTokens, 100)
        XCTAssertEqual(record.cacheReadTokens, 0)
    }

    func testIncrementalFetchReturnsOnlyAppendedRecords() async throws {
        let url = try writeSessionFile(name: "session-2026-09-10T18-13-00-abc.jsonl", lines: [
            #"{"sessionId":"sess-1","messages":[]}"#,
            #"{"id":"m2","timestamp":"2026-09-10T18:13:22.500Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":1000,"output":300,"cached":200,"thoughts":50,"total":1350}}"#,
        ])

        let adapter = GeminiAdapter()
        let geminiRoot = tempDir.appendingPathComponent("gemini")
        let first = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: nil)
        XCTAssertEqual(first.records.count, 1)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let appended = Data(#"{"id":"m9","timestamp":"2026-09-10T18:30:00Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":10,"output":20,"total":30}}"#.appending("\n").utf8)
        try handle.write(contentsOf: appended)

        // Incremental sync parses only the appended complete lines and emits
        // only the new record; unchanged history is not re-sent (the database
        // INSERT OR IGNORE dedupe no longer relies on re-emission).
        let second = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 1)
        let record = try XCTUnwrap(second.records.first)
        XCTAssertEqual(record.id, "gemini_sess-1_m9")
        XCTAssertEqual(record.inputTokens, 10)
        XCTAssertEqual(record.outputTokens, 20)
    }

    func testUnchangedFilesSkippedAndFallbackIdsStableAfterAppend() async throws {
        // Two files, each with an id-less gemini message. Unchanged files are
        // skipped entirely on the next sync; after an append only the new
        // line is emitted, and a cursor-less full re-parse must mint the same
        // offset-based fallback ids (absolute line numbers) so historical
        // rows deduplicate instead of duplicating.
        _ = try writeSessionFile(name: "session-a.jsonl", lines: [
            #"{"sessionId":"sess-a","messages":[]}"#,
            #"{"timestamp":"2026-09-10T18:13:22.500Z","type":"gemini","tokens":{"input":10,"output":5}}"#,
        ])
        _ = try writeSessionFile(name: "session-b.jsonl", lines: [
            #"{"sessionId":"sess-b","messages":[]}"#,
            #"{"timestamp":"2026-09-10T18:14:22.500Z","type":"gemini","tokens":{"input":20,"output":6}}"#,
        ])

        let adapter = GeminiAdapter()
        let geminiRoot = tempDir.appendingPathComponent("gemini")
        let first = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: nil)
        XCTAssertEqual(first.records.count, 2)
        let historicalId = try XCTUnwrap(first.records.first(where: { $0.sessionKey == "sess-a" })?.id)

        let second = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 0, "unchanged session files should be skipped")

        // Append an id-less message to session-a: only the appended line is
        // parsed and emitted, carrying its absolute-line fallback id.
        _ = try writeSessionFile(name: "session-a.jsonl", lines: [
            #"{"sessionId":"sess-a","messages":[]}"#,
            #"{"timestamp":"2026-09-10T18:13:22.500Z","type":"gemini","tokens":{"input":10,"output":5}}"#,
            #"{"timestamp":"2026-09-10T18:15:22.500Z","type":"gemini","tokens":{"input":30,"output":7}}"#,
        ])

        let third = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: second.newCursor)
        XCTAssertEqual(third.records.count, 1)
        let appended = try XCTUnwrap(third.records.first)
        XCTAssertEqual(appended.id, "gemini_sess-a_offset_2")
        XCTAssertEqual(appended.inputTokens, 30)
        XCTAssertEqual(appended.outputTokens, 7)

        // Losing the cursor forces a full re-parse; the historical row's
        // fallback id must be identical to the one minted by the first sync,
        // so INSERT OR IGNORE still deduplicates it.
        let full = try await adapter.fetchIncrementalRecords(from: geminiRoot, since: nil)
        XCTAssertEqual(
            Set(full.records.map(\.id)),
            ["gemini_sess-a_offset_1", "gemini_sess-a_offset_2", "gemini_sess-b_offset_1"]
        )
        XCTAssertEqual(full.records.first(where: { $0.sessionKey == "sess-a" })?.id, historicalId)
    }

    func testAdapterMetadata() {
        let adapter = GeminiAdapter()
        XCTAssertEqual(adapter.sourceId, "gemini")
        XCTAssertEqual(adapter.displayName, "Gemini CLI")
        XCTAssertEqual(adapter.brandColorHex, "#4285F4")
        XCTAssertEqual(adapter.sfSymbolIcon, "diamond.fill")
    }

    func testDefaultPathFromProtocolExtension() {
        let adapter = GeminiAdapter()
        XCTAssertEqual(adapter.defaultPath, "~/.gemini")
    }

    func testDetectDefaultPathMissingDirectory() {
        let adapter = GeminiAdapter()
        // The real ~/.gemini may or may not exist; just verify the call completes.
        _ = adapter.detectDefaultPath()
    }
}
