import XCTest
@testable import BennettUsageCore

final class ContinueAdapterTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionsRoot: URL!
    private let adapter = ContinueAdapter()
    private let sessionId = "11111111-1111-4111-8111-111111111111"

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-adapter-\(UUID().uuidString)", isDirectory: true)
        sessionsRoot = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testParsesNestedSchemaAndNormalizesOpenAIUsage() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_735_776_245.678)
        let file = try writeSession("""
        {
          "sessionId": "\(sessionId)",
          "workspaceDirectory": "/Users/test/continue-project",
          "history": [
            {"message": {"role": "user", "content": "question", "usage": {"prompt_tokens": 9999, "completion_tokens": 9999, "prompt_tokens_details": {}}}},
            {"message": {"role": "assistant", "content": "answer", "usage": {
              "prompt_tokens": 1200,
              "completion_tokens": 80,
              "prompt_tokens_details": {"cached_tokens": 1000, "cache_write_tokens": 50},
              "model": "vendor/model-redacted",
              "cost_cents": 12
            }}}
          ],
          "usage": {"promptTokens": 999999, "completionTokens": 999999}
        }
        """, modifiedAt: modifiedAt)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 1)

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.sourceId, "continue")
        XCTAssertEqual(record.sessionKey, sessionId)
        XCTAssertEqual(record.projectFolder, "/Users/test/continue-project")
        XCTAssertEqual(record.inputTokens, 150)
        XCTAssertEqual(record.outputTokens, 80)
        XCTAssertEqual(record.cacheReadTokens, 1_000)
        XCTAssertEqual(record.cacheWriteTokens, 50)
        XCTAssertEqual(record.rawCostUSD ?? 0, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(record.model, "vendor/model-redacted")
        XCTAssertNil(record.provider)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, modifiedAt.timeIntervalSince1970, accuracy: 0.001)

        let checkpoint = cursorEntries(result.newCursor)
        let checkpointPath = try XCTUnwrap(checkpoint.keys.first {
            $0.hasSuffix(".json") && !$0.contains("::")
        })
        XCTAssertEqual(checkpoint[checkpointPath], Int64(modifiedAt.timeIntervalSince1970 * 1_000))
        XCTAssertNotNil(checkpoint[checkpointPath + "::size"])
        XCTAssertNotNil(checkpoint[checkpointPath + "::fileIdentity"])

        // The index file is not a session and must never become a usage source.
        try #"{"history":[{"message":{"role":"assistant","usage":{"prompt_tokens":8,"completion_tokens":9,"prompt_tokens_details":{}}}}]}"#
            .write(to: sessionsRoot.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)

        let withIndex = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(withIndex.records.count, 1)
        XCTAssertEqual(cursorEntries(withIndex.newCursor)[file.path], cursorEntries(result.newCursor)[file.path])
    }

    func testCacheReadSynonymsAreAlternativesAndOversizedCacheUsageIsSkipped() async throws {
        try writeSession("""
        {
          "sessionId": "\(sessionId)",
          "workspaceDirectory": "/workspace",
          "history": [
            {"message":{"role":"assistant","content":"a","usage":{"prompt_tokens":1200,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":1000,"cache_write_tokens":50}}}},
            {"message":{"role":"assistant","content":"b","usage":{"prompt_tokens":1200,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":1000,"cache_read_tokens":900,"cache_write_tokens":20}}}},
            {"message":{"role":"assistant","content":"c","usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":80,"cache_read_tokens":90,"cache_write_tokens":20}}}}
          ]
        }
        """)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.map(\.cacheReadTokens), [1_000, 900])
        XCTAssertEqual(result.records.map(\.inputTokens), [150, 280])
    }

    func testMissingOrMalformedUsageDoesNotCreateZeroRecords() async throws {
        try writeSession("""
        {
          "sessionId": "\(sessionId)",
          "history": [
            {"message":{"role":"assistant","content":"missing"}},
            {"message":{"role":"assistant","content":"empty","usage":{}}},
            {"message":{"role":"assistant","content":"bad prompt","usage":{"prompt_tokens":"many","completion_tokens":3,"prompt_tokens_details":{}}}},
            {"message":{"role":"assistant","content":"bad details","usage":{"prompt_tokens":3,"completion_tokens":4,"prompt_tokens_details":[]}}},
            {"message":{"role":"assistant","content":"bad cache","usage":{"prompt_tokens":3,"completion_tokens":4,"prompt_tokens_details":{"cache_read_tokens":"bad","cached_tokens":2}}}}
          ]
        }
        """)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testRecordIDsAreNamespacedBySession() async throws {
        let secondSessionId = "22222222-2222-4222-8222-222222222222"
        let history = """
        [{"message":{"role":"assistant","content":"same answer","usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{}}}}]
        """
        try #"{"sessionId":"\#(sessionId)","history":\#(history)}"#
            .write(to: sessionsRoot.appendingPathComponent("\(sessionId).json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"\#(secondSessionId)","history":\#(history)}"#
            .write(to: sessionsRoot.appendingPathComponent("\(secondSessionId).json"), atomically: true, encoding: .utf8)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.map(\.id)).count, 2)

        let bySession = Dictionary(uniqueKeysWithValues: result.records.map { ($0.sessionKey, $0) })
        for record in bySession.values {
            let components = record.id.split(separator: "_", omittingEmptySubsequences: false)
            XCTAssertEqual(components.count, 4)
            XCTAssertEqual(components[0], "continue")
            XCTAssertEqual(components[1].count, 64)
            XCTAssertEqual(components[2].count, 64)
            XCTAssertEqual(components[3], "0")
            XCTAssertTrue(components.dropFirst().allSatisfy { component in
                component.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            })
        }
        XCTAssertNotEqual(bySession[sessionId]?.id, bySession[secondSessionId]?.id)
    }

    func testMalformedJSONDoesNotAdvanceCheckpointAndRepairsLater() async throws {
        let file = try writeSession(sessionWithoutUsageJSON(content: "before"))
        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        let firstCursor = cursorEntries(first.newCursor)
        XCTAssertTrue(first.records.isEmpty)

        try Data("{ broken".utf8).write(to: file)
        try setModificationDate(file, Date(timeIntervalSince1970: 2_000))
        let malformed = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertTrue(malformed.records.isEmpty)
        XCTAssertEqual(cursorEntries(malformed.newCursor), firstCursor)

        try validSessionJSON(content: "after", title: "changed size").write(to: file, atomically: true, encoding: .utf8)
        try setModificationDate(file, Date(timeIntervalSince1970: 3_000))
        let repaired = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: malformed.newCursor)
        XCTAssertEqual(repaired.records.count, 1)
        XCTAssertEqual(repaired.records[0].inputTokens, 20)
        XCTAssertNotEqual(cursorEntries(repaired.newCursor), firstCursor)
    }

    func testSizeOrModificationTimeChangeReparsesWholeFileAndRepeatScanIsIdempotent() async throws {
        let file = try writeSession(sessionWithoutUsageJSON(content: "before"))
        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertTrue(first.records.isEmpty)

        try validSessionJSON(content: "after", title: "a title that makes the snapshot larger")
            .write(to: file, atomically: true, encoding: .utf8)
        try setModificationDate(file, Date(timeIntervalSince1970: 4_000))

        let changed = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertEqual(changed.records.count, 1)
        XCTAssertEqual(changed.records[0].outputTokens, 5)

        let repeated = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: changed.newCursor)
        XCTAssertTrue(repeated.records.isEmpty)
        XCTAssertEqual(cursorEntries(repeated.newCursor), cursorEntries(changed.newCursor))
    }

    func testRejectsInvalidUUIDAndMismatchedSessionID() async throws {
        try #"{"sessionId":"\(sessionId)","history":[]}"#
            .write(to: sessionsRoot.appendingPathComponent("not-a-uuid.json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"22222222-2222-4222-8222-222222222222","history":[]}"#
            .write(to: sessionsRoot.appendingPathComponent("\(sessionId).json"), atomically: true, encoding: .utf8)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(cursorEntries(result.newCursor).isEmpty)
    }

    func testSemanticDuplicatesGetOccurrenceIDsAndUsageCompletionKeepsID() async throws {
        let duplicate = """
        {"message":{"role":"assistant","content":[{"type":"text","text":"same"}],
          "toolCalls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"README.md\\"}"}}],
          "usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{}}}}
        """
        try writeSession("""
        {"sessionId":"\(sessionId)","workspaceDirectory":"/workspace","history":[
          {"message":{"role":"assistant","content":"unique","usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_tokens_details":{}}}},
          \(duplicate),
          \(duplicate)
        ]}
        """)

        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(first.records.count, 3)
        XCTAssertEqual(Set(first.records.map(\.id)).count, 3)
        XCTAssertTrue(first.records[1].id.hasSuffix("_0"))
        XCTAssertTrue(first.records[2].id.hasSuffix("_1"))

        let completed = duplicate.replacingOccurrences(
            of: #""prompt_tokens":10,"completion_tokens":2"#,
            with: #""prompt_tokens":25,"completion_tokens":7"#
        )
        try writeSession("""
        {"sessionId":"\(sessionId)","workspaceDirectory":"/workspace","history":[
          {"message":{"role":"assistant","content":"unique","usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_tokens_details":{}}}},
          \(completed)
        ]}
        """)
        try setModificationDate(sessionsRoot.appendingPathComponent("\(sessionId).json"), Date(timeIntervalSince1970: 5_000))

        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 2)
        XCTAssertEqual(second.records[1].id, first.records[1].id)
        XCTAssertEqual(second.records[1].inputTokens, 25)
        XCTAssertEqual(second.records[1].outputTokens, 7)

        let database = try DatabaseManager.inMemory()
        XCTAssertEqual(try database.insertRecords(first.records), 3)
        XCTAssertEqual(try database.insertRecords(second.records), 0)
        XCTAssertEqual(try database.fetchTotalRecordCount(), 3)
    }

    func testContinueGlobalDirectoryOverrideMustBeAbsolute() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            ContinueAdapter.sessionsRoot(environment: ["CONTINUE_GLOBAL_DIR": "/opt/continue-global"], home: home).path,
            "/opt/continue-global/sessions"
        )
        XCTAssertEqual(
            ContinueAdapter.sessionsRoot(environment: ["CONTINUE_GLOBAL_DIR": "relative/continue"], home: home).path,
            "/Users/example/.continue/sessions"
        )
        XCTAssertEqual(
            ContinueAdapter.sessionsRoot(environment: [:], home: home).path,
            "/Users/example/.continue/sessions"
        )
    }

    func testMetadataAndIncompatibleCursorStillPerformAFullScan() async throws {
        XCTAssertEqual(adapter.sourceId, "continue")
        XCTAssertEqual(adapter.displayName, "Continue CLI")
        XCTAssertEqual(adapter.defaultPath, "~/.continue/sessions")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "continue"), "Continue CLI")

        try writeSession(validSessionJSON(content: "scan"))
        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: .rowId(999))
        XCTAssertEqual(result.records.count, 1)
    }

    private func validSessionJSON(content: String, title: String = "Session") -> String {
        """
        {"sessionId":"\(sessionId)","title":"\(title)","workspaceDirectory":"/workspace","history":[
          {"message":{"role":"assistant","content":"\(content)","usage":{"prompt_tokens":20,"completion_tokens":5,"prompt_tokens_details":{}}}}
        ]}
        """
    }

    private func sessionWithoutUsageJSON(content: String, title: String = "Session") -> String {
        """
        {"sessionId":"\(sessionId)","title":"\(title)","workspaceDirectory":"/workspace","history":[
          {"message":{"role":"assistant","content":"\(content)"}}
        ]}
        """
    }

    @discardableResult
    private func writeSession(_ json: String, modifiedAt: Date = Date()) throws -> URL {
        let file = sessionsRoot.appendingPathComponent("\(sessionId).json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        try setModificationDate(file, modifiedAt)
        return file
    }

    private func setModificationDate(_ file: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func cursorEntries(_ cursor: SyncCursor) -> [String: Int64] {
        guard case .fileOffsets(let entries) = cursor else { return [:] }
        return entries
    }
}
