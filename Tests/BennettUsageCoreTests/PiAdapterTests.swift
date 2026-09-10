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

    func testPiAdapterMetadata() {
        let adapter = PiAdapter()
        XCTAssertEqual(adapter.sourceId, "pi")
        XCTAssertEqual(adapter.displayName, "Pi Agent")
        XCTAssertEqual(adapter.brandColorHex, "#10B981")
        XCTAssertEqual(adapter.sfSymbolIcon, "sparkle")
    }

    func testPiAdapterDetectDefaultPath() {
        let adapter = PiAdapter()
        _ = adapter.detectDefaultPath()
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
        XCTAssertEqual(result1.records[0].cacheReadTokens, 50)
        XCTAssertEqual(result1.records[0].cacheWriteTokens, 20)
        XCTAssertEqual(result1.records[0].totalTokens, 670)
        XCTAssertEqual(result1.records[0].model, "claude-3-5-sonnet")
        XCTAssertEqual(result1.records[0].sessionKey, "test_session.jsonl")
        XCTAssertEqual(result1.records[0].projectFolder, "/Users/ruanbw/projects/myproject")

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
        XCTAssertEqual(result2.records[0].outputTokens, 80)

        // Third fetch with no new data returns 0 records
        let result3 = try await adapter.fetchIncrementalRecords(from: tempDir, since: result2.newCursor)
        XCTAssertEqual(result3.records.count, 0)
    }

    func testPiAdapterStreamingPartialLineSafety() async throws {
        let fileUrl = sessionFolder.appendingPathComponent("partial.jsonl")
        // Write complete line 1 followed by incomplete line 2 (no trailing newline)
        let line1 = """
        {"type":"message","timestamp":"2026-09-11T01:00:00.000Z","model":"gpt-4o","usage":{"prompt_tokens":100,"completion_tokens":50}}\n
        """
        let partialLine2 = """
        {"type":"message","timestamp":"2026-09-11T01:05:00.000Z","model":"gpt-4o","usage":{"prompt_tokens":200
        """
        try (line1 + partialLine2).write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result1 = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        // Only line 1 should be parsed
        XCTAssertEqual(result1.records.count, 1)
        XCTAssertEqual(result1.records[0].inputTokens, 100)

        // Now finish writing line 2 with newline
        let restOfLine2 = """
        ,"completion_tokens":75}}\n
        """
        let handle = try FileHandle(forWritingTo: fileUrl)
        try handle.seekToEnd()
        try handle.write(contentsOf: restOfLine2.data(using: .utf8)!)
        try handle.close()

        // Second fetch with cursor should now parse line 2
        let result2 = try await adapter.fetchIncrementalRecords(from: tempDir, since: result1.newCursor)
        XCTAssertEqual(result2.records.count, 1)
        XCTAssertEqual(result2.records[0].inputTokens, 200)
        XCTAssertEqual(result2.records[0].outputTokens, 75)
    }

    func testPiAdapterAlternativeTokenKeysAndNoFolderDecoding() async throws {
        let plainFolder = tempDir.appendingPathComponent("plain-folder-name")
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        let fileUrl = plainFolder.appendingPathComponent("session2.jsonl")

        // Using input_tokens / output_tokens instead of prompt_tokens / completion_tokens
        let line = """
        {"type":"message","timestamp":"2026-09-11T03:00:00Z","model":"gemini-2.0-flash","usage":{"input_tokens":450,"output_tokens":150}}\n
        """
        try line.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].inputTokens, 450)
        XCTAssertEqual(result.records[0].outputTokens, 150)
        XCTAssertEqual(result.records[0].model, "gemini-2.0-flash")
        XCTAssertNil(result.records[0].projectFolder)
    }

    func testPiAdapterSkipsMalformedLinesAndNonJsonlFiles() async throws {
        let fileUrl = sessionFolder.appendingPathComponent("malformed.jsonl")
        let nonJsonl = sessionFolder.appendingPathComponent("notes.txt")
        try "Some notes".write(to: nonJsonl, atomically: true, encoding: .utf8)

        let content = """
        not valid json\n
        {"missing_usage": true}\n
        \n
        {"type":"message","timestamp":"2026-09-11T04:00:00.000Z","model":"claude-3-5-haiku","usage":{"prompt_tokens":80,"completion_tokens":20}}\n
        """
        try content.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].inputTokens, 80)
        XCTAssertEqual(result.records[0].outputTokens, 20)
        XCTAssertEqual(result.records[0].model, "claude-3-5-haiku")
    }

    func testPiAdapterNestedMessageUsageAndCwd() async throws {
        let customFolder = tempDir.appendingPathComponent("--Users-ruanbw-projects-fallback--")
        try FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        let fileUrl = customFolder.appendingPathComponent("nested_session.jsonl")

        let line = """
        {"type":"message","timestamp":"2026-09-11T05:00:00.000Z","cwd":"/Users/ruanbw/custom-cwd","message":{"role":"assistant","model":"claude-3-7-sonnet","usage":{"input":1200,"output":350,"cacheRead":150,"cacheWrite":75,"cost":{"total":0.0125}}}}\n
        """
        try line.write(to: fileUrl, atomically: true, encoding: .utf8)

        let adapter = PiAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        let rec = result.records[0]
        XCTAssertEqual(rec.sourceId, "pi")
        XCTAssertEqual(rec.inputTokens, 1200)
        XCTAssertEqual(rec.outputTokens, 350)
        XCTAssertEqual(rec.cacheReadTokens, 150)
        XCTAssertEqual(rec.cacheWriteTokens, 75)
        XCTAssertEqual(rec.totalTokens, 1775)
        XCTAssertEqual(rec.model, "claude-3-7-sonnet")
        XCTAssertEqual(rec.rawCostUSD, 0.0125)
        XCTAssertEqual(rec.projectFolder, "/Users/ruanbw/custom-cwd")
        XCTAssertTrue(rec.id.hasPrefix("pi_--Users-ruanbw-projects-fallback--_nested_session_"))
    }
}
