import Darwin
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
        XCTAssertEqual(record.timestampSource, .sourceModified)

        let checkpoint = generationEntries(result.newCursor)
        let checkpointPath = try XCTUnwrap(checkpoint.keys.first { $0.hasSuffix(".json") })
        let fileCheckpoint = try XCTUnwrap(checkpoint[checkpointPath])
        XCTAssertEqual(fileCheckpoint.offset, Int64(try Data(contentsOf: file).count))
        XCTAssertEqual(fileCheckpoint.size, fileCheckpoint.offset)
        XCTAssertEqual(fileCheckpoint.generation.count, 64)

        // The index file is not a session and must never become a usage source.
        try #"{"history":[{"message":{"role":"assistant","usage":{"prompt_tokens":8,"completion_tokens":9,"prompt_tokens_details":{}}}}]}"#
            .write(to: sessionsRoot.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)

        let withIndex = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(withIndex.records.count, 1)
        XCTAssertEqual(generationEntries(withIndex.newCursor)[ContinueAdapter.canonicalPath(for: file)], generationEntries(result.newCursor)[ContinueAdapter.canonicalPath(for: file)])
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
        let firstCursor = generationEntries(first.newCursor)
        XCTAssertTrue(first.records.isEmpty)

        try Data("{ broken".utf8).write(to: file)
        try setModificationDate(file, Date(timeIntervalSince1970: 2_000))
        let malformed = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertTrue(malformed.records.isEmpty)
        XCTAssertEqual(generationEntries(malformed.newCursor), firstCursor)

        try validSessionJSON(content: "after", title: "changed size").write(to: file, atomically: true, encoding: .utf8)
        try setModificationDate(file, Date(timeIntervalSince1970: 3_000))
        let repaired = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: malformed.newCursor)
        XCTAssertEqual(repaired.records.count, 1)
        XCTAssertEqual(repaired.records[0].inputTokens, 20)
        XCTAssertNotEqual(generationEntries(repaired.newCursor), firstCursor)
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
        XCTAssertEqual(generationEntries(repeated.newCursor), generationEntries(changed.newCursor))
    }

    func testRewriteAfterUnchangedPrefixChangesGeneration() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 5_500)
        let firstHistory = """
        {"message":{"role":"assistant","content":"stable","usage":{"prompt_tokens":10,"completion_tokens":1,"prompt_tokens_details":{}}}}
        {"message":{"role":"assistant","content":"rewritten","usage":{"prompt_tokens":20,"completion_tokens":2,"prompt_tokens_details":{}}}}
        """
        let file = try writeSession(
            "{\"sessionId\":\"\(sessionId)\",\"history\":[\(firstHistory)]}",
            modifiedAt: modifiedAt
        )
        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        let firstGeneration = try XCTUnwrap(generationEntries(first.newCursor)[ContinueAdapter.canonicalPath(for: file)]).generation

        let rewrittenHistory = firstHistory.replacingOccurrences(
            of: #""completion_tokens":2"#,
            with: #""completion_tokens":9"#
        )
        XCTAssertEqual(Data(rewrittenHistory.utf8).count, Data(firstHistory.utf8).count)
        try Data("{\"sessionId\":\"\(sessionId)\",\"history\":[\(rewrittenHistory)]}".utf8).write(to: file)
        try setModificationDate(file, modifiedAt)

        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 2)
        XCTAssertNotEqual(generationEntries(second.newCursor)[ContinueAdapter.canonicalPath(for: file)]?.generation, firstGeneration)
        XCTAssertEqual(second.records[0].id, first.records[0].id)
        XCTAssertEqual(second.records[1].outputTokens, 9)
    }

    func testSameSizeAndModificationTimeContentRewriteChangesGeneration() async throws {
        let modifiedAt = Date(timeIntervalSince1970: 6_000)
        let file = try writeSession(
            validSessionJSON(content: "same", completionTokens: 5),
            modifiedAt: modifiedAt
        )
        let originalIdentity = try fileIdentity(file)

        let first = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records[0].outputTokens, 5)
        let firstGeneration = try XCTUnwrap(generationEntries(first.newCursor)[ContinueAdapter.canonicalPath(for: file)]).generation

        let rewritten = validSessionJSON(content: "same", completionTokens: 9)
        XCTAssertEqual(Data(rewritten.utf8).count, try Data(contentsOf: file).count)
        // A non-atomic write preserves the inode as well as the explicitly
        // restored size and mtime, so only the content hash can detect it.
        try Data(rewritten.utf8).write(to: file)
        try setModificationDate(file, modifiedAt)
        XCTAssertEqual(try fileIdentity(file), originalIdentity)
        XCTAssertEqual(try fileSize(file), Int64(rewritten.utf8.count))
        XCTAssertEqual(try fileModificationDate(file).timeIntervalSince1970,
                       modifiedAt.timeIntervalSince1970,
                       accuracy: 0.001)

        let second = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: first.newCursor)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertEqual(second.records[0].id, first.records[0].id)
        XCTAssertEqual(second.records[0].outputTokens, 9)
        let secondCheckpoint = try XCTUnwrap(generationEntries(second.newCursor)[ContinueAdapter.canonicalPath(for: file)])
        XCTAssertNotEqual(secondCheckpoint.generation, firstGeneration)
        XCTAssertEqual(secondCheckpoint.size, secondCheckpoint.offset)
    }

    func testLegacyOffsetCursorMigratesOnceToFileGenerations() async throws {
        let file = try writeSession(validSessionJSON(content: "legacy"))
        let initial = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertEqual(initial.records.count, 1)
        let initialGeneration = try XCTUnwrap(generationEntries(initial.newCursor)[ContinueAdapter.canonicalPath(for: file)])

        let migrated = try await adapter.fetchIncrementalRecords(
            from: sessionsRoot,
            since: .fileOffsets([file.path: 1])
        )

        XCTAssertEqual(migrated.records.count, 1)
        XCTAssertEqual(migrated.records[0].id, initial.records[0].id)
        XCTAssertEqual(generationEntries(migrated.newCursor)[ContinueAdapter.canonicalPath(for: file)], initialGeneration)

        let repeated = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: migrated.newCursor)
        XCTAssertTrue(repeated.records.isEmpty)
        XCTAssertEqual(generationEntries(repeated.newCursor), generationEntries(migrated.newCursor))
    }

    func testRejectsInvalidUUIDAndMismatchedSessionID() async throws {
        try #"{"sessionId":"\(sessionId)","history":[]}"#
            .write(to: sessionsRoot.appendingPathComponent("not-a-uuid.json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"22222222-2222-4222-8222-222222222222","history":[]}"#
            .write(to: sessionsRoot.appendingPathComponent("\(sessionId).json"), atomically: true, encoding: .utf8)

        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: nil)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(generationEntries(result.newCursor).isEmpty)
    }

    func testCompactionCutsOverInsteadOfCorrectingReusedOccurrenceID() async throws {
        let duplicate = """
        {"message":{"role":"assistant","content":[{"type":"text","text":"same"}],
          "toolCalls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"README.md\\"}"}}],
          "usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{}}}}
        """
        let file = try writeSession("""
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
        XCTAssertNotEqual(second.records[1].id, first.records[2].id)
        XCTAssertEqual(second.records[1].inputTokens, 25)
        XCTAssertEqual(second.records[1].outputTokens, 7)
        XCTAssertNotEqual(generationEntries(second.newCursor)[ContinueAdapter.canonicalPath(for: file)]?.generation,
                          generationEntries(first.newCursor)[ContinueAdapter.canonicalPath(for: file)]?.generation)

        // Coordinator cutover semantics replace the complete source snapshot.
        // In particular, old occurrence _1 must not survive beside the new _0.
        let database = try DatabaseManager.inMemory()
        XCTAssertEqual(try database.insertRecords(
            first.records,
            updateCursorFor: adapter.sourceId,
            cursor: first.newCursor
        ), 3)
        _ = try database.replaceSourceRecords(
            second.records,
            sourceId: adapter.sourceId,
            cursor: second.newCursor
        )
        let stored = try database.fetchRecords(sinceTimestamp: 0)
        XCTAssertEqual(Set(stored.map(\.id)), Set(second.records.map(\.id)))
        XCTAssertFalse(stored.contains { $0.id == first.records[2].id })
        let compacted = try XCTUnwrap(stored.first { $0.id == second.records[1].id })
        XCTAssertEqual(compacted.inputTokens, 25)
        XCTAssertEqual(compacted.outputTokens, 7)
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
        XCTAssertFalse(adapter.supportsRecordCorrections)
        XCTAssertEqual(AgentFilterBarView.displayName(for: "continue"), "Continue CLI")

        try writeSession(validSessionJSON(content: "scan"))
        let result = try await adapter.fetchIncrementalRecords(from: sessionsRoot, since: .rowId(999))
        XCTAssertEqual(result.records.count, 1)
    }

    private func validSessionJSON(
        content: String,
        title: String = "Session",
        completionTokens: Int = 5
    ) -> String {
        """
        {"sessionId":"\(sessionId)","title":"\(title)","workspaceDirectory":"/workspace","history":[
          {"message":{"role":"assistant","content":"\(content)","usage":{"prompt_tokens":20,"completion_tokens":\(completionTokens),"prompt_tokens_details":{}}}}
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

    private func fileIdentity(_ file: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return info.st_ino
    }

    private func fileSize(_ file: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
    }

    private func fileModificationDate(_ file: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func generationEntries(_ cursor: SyncCursor) -> [String: FileGeneration] {
        guard case .fileGenerations(let entries) = cursor else { return [:] }
        return entries
    }
}
