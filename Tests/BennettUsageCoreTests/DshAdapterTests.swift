import XCTest
@testable import BennettUsageCore

final class DshAdapterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDshAdapterMetadata() {
        let adapter = DshAdapter()
        XCTAssertEqual(adapter.sourceId, "dsh")
        XCTAssertEqual(adapter.displayName, "DSH Harness")
        XCTAssertEqual(adapter.brandColorHex, "#4D6BFE")
        XCTAssertFalse(adapter.isSyncStub)
        _ = adapter.detectDefaultPath()
        XCTAssertEqual(AgentFilterBarView.displayName(for: "dsh"), "DSH Harness")
    }

    func testParseTranscriptPerStepUsage() {
        // Mirrors the real v3 transcript shape: header line + assistant
        // settlements carrying data.usage buckets.
        let jsonl = """
        {"type":"session","version":3,"id":"session-abc","createdAt":1789320969837,"cwd":"/Users/test/proj"}\n
        {"type":"turn/start","seq":4,"time":1789321014195,"data":{"turn":1}}\n
        {"type":"assistant/message","seq":15,"time":1789321017034,"data":{"turn":1,"step":1,"message":{"role":"assistant","source":{"kind":"model","provider":"opencode-go","model":"muse-spark-1.3-contributor"},"id":"m1"},"usage":{"inputTokens":3853,"outputTokens":91,"totalTokens":12633,"cacheReadTokens":8689}}}\n
        {"type":"assistant/message","seq":20,"time":1789321020124,"data":{"turn":1,"step":2,"message":{"role":"assistant","source":{"kind":"model","provider":"opencode-go","model":"muse-spark-1.3-contributor"},"id":"m2"},"usage":{"inputTokens":1301,"outputTokens":210,"totalTokens":14040,"cacheReadTokens":12529}}}\n
        {"type":"assistant/message","seq":21,"time":1789321020200,"data":{"turn":1,"step":3,"message":{"role":"assistant","source":{"kind":"model"},"id":"m3"},"usage":{"inputTokens":0,"outputTokens":0,"totalTokens":0,"cacheReadTokens":0}}}\n
        """
        let records = DshAdapter.parseTranscript(
            Data(jsonl.utf8), mungedFolder: "--Users-test-proj--", sourceId: "dsh")
        // Zero-usage settlement (seq 21) is skipped.
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, "dsh_session-abc_15")
        XCTAssertEqual(records[0].sourceId, "dsh")
        XCTAssertEqual(records[0].inputTokens, 3853)
        XCTAssertEqual(records[0].outputTokens, 91)
        XCTAssertEqual(records[0].cacheReadTokens, 8689)
        XCTAssertEqual(records[0].model, "muse-spark-1.3-contributor")
        XCTAssertEqual(records[0].provider, "opencode-go")
        XCTAssertEqual(records[0].sessionKey, "session-abc")
        XCTAssertEqual(records[0].projectFolder, "/Users/test/proj")
        XCTAssertEqual(records[1].id, "dsh_session-abc_20")
        XCTAssertEqual(records[1].inputTokens, 1301)
    }

    func testProjcacheFallbackEmitsDeltas() async throws {
        // No sessions tree and no zstd decode involved: the plain-JSON
        // projcache carries cumulative totals; syncs emit deltas.
        let cacheDir = tempDir.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("session-xyz.json")
        func writeCache(inTotal: Int, out: Int, read: Int) throws {
            let json = """
            {"version":7,"record":{"identity":{"createdAt":1789320969837,"cwd":"/Users/test/proj"},"rows":{"tokenUsage":{"ver":2,"seq":10,"val":{"totals":{"uncachedInputTokens":\(inTotal),"outputTokens":\(out),"cacheReadTokens":\(read),"cacheWriteTokens":0}}}}}}
            """
            try json.write(to: cacheFile, atomically: true, encoding: .utf8)
        }
        try writeCache(inTotal: 1000, out: 200, read: 5000)

        let adapter = DshAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records[0].id, "dsh_session-xyz_cum_1000_200_5000_0")
        XCTAssertEqual(first.records[0].inputTokens, 1000)
        XCTAssertEqual(first.records[0].outputTokens, 200)
        XCTAssertEqual(first.records[0].cacheReadTokens, 5000)
        XCTAssertEqual(first.records[0].sessionKey, "session-xyz")
        XCTAssertEqual(first.records[0].projectFolder, "/Users/test/proj")
        XCTAssertNotEqual(first.records[0].model, "dsh", "model must never be 'dsh'")
        XCTAssertEqual(first.records[0].model, "unknown")

        // No growth -> no records.
        let second = try await adapter.fetchIncrementalRecords(from: tempDir, since: first.newCursor)
        XCTAssertEqual(second.records.count, 0)

        // Growth -> delta only.
        try writeCache(inTotal: 1500, out: 250, read: 8000)
        let third = try await adapter.fetchIncrementalRecords(from: tempDir, since: second.newCursor)
        XCTAssertEqual(third.records.count, 1)
        XCTAssertEqual(third.records[0].inputTokens, 500)
        XCTAssertEqual(third.records[0].outputTokens, 50)
        XCTAssertEqual(third.records[0].cacheReadTokens, 3000)
        XCTAssertNotEqual(third.records[0].model, "dsh")
    }

    func testProjcacheExtractsModelFromModelSelection() async throws {
        let cacheDir = tempDir.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("session-ms.json")
        let json = """
        {
          "version": 7,
          "record": {
            "identity": { "createdAt": 1789320969837, "cwd": "/Users/test/proj" },
            "rows": {
              "modelSelection": {
                "val": {
                  "lastUsed": {
                    "provider": "cliprox",
                    "model": "gemini-3.8-flash-high",
                    "reasoningEffort": "high"
                  }
                }
              },
              "tokenUsage": {
                "val": {
                  "totals": {
                    "uncachedInputTokens": 1000,
                    "outputTokens": 200,
                    "cacheReadTokens": 5000,
                    "cacheWriteTokens": 0
                  }
                }
              }
            }
          }
        }
        """
        try json.write(to: cacheFile, atomically: true, encoding: .utf8)

        let adapter = DshAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].model, "gemini-3.8-flash-high")
        XCTAssertEqual(result.records[0].provider, "cliprox")
    }

    func testProjcacheWithoutModelFallsBackToUnknown() async throws {
        let cacheDir = tempDir.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("session-no-model.json")
        let json = """
        {
          "version": 7,
          "record": {
            "identity": { "createdAt": 1789320969837, "cwd": "/Users/test/proj" },
            "rows": {
              "tokenUsage": {
                "val": {
                  "totals": {
                    "uncachedInputTokens": 1000,
                    "outputTokens": 200,
                    "cacheReadTokens": 5000,
                    "cacheWriteTokens": 0
                  }
                }
              }
            }
          }
        }
        """
        try json.write(to: cacheFile, atomically: true, encoding: .utf8)

        let adapter = DshAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].model, "unknown")
        XCTAssertEqual(result.records[0].provider, "unknown")
        XCTAssertNotEqual(result.records[0].model, "dsh")
    }

    func testDecodeMungedFolder() {
        XCTAssertEqual(
            DshAdapter.decodeMungedFolder("--Users-ruanbw-projects-bennett-usage--"),
            "/Users/ruanbw/projects/bennett-usage")
        XCTAssertNil(DshAdapter.decodeMungedFolder("plain"))
    }

    func testConsecutiveSyncWithTranscriptAndProjcacheDoesNotDoubleCount() async throws {
        let sessionId = "session-consecutive-test"
        let projectFolder = "/Users/test/proj"
        let mungedFolder = "--Users-test-proj--"

        // 1. Create transcript .jsonl file for the session
        let sessionDir = tempDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(mungedFolder, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcriptFile = sessionDir.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"type":"session","version":3,"id":"\(sessionId)","createdAt":1789320969837,"cwd":"\(projectFolder)"}\n
        {"type":"turn/start","seq":1,"time":1789321014195,"data":{"turn":1}}\n
        {"type":"assistant/message","seq":2,"time":1789321017034,"data":{"turn":1,"step":1,"message":{"role":"assistant","source":{"kind":"model","provider":"opencode-go","model":"muse-spark-1.3-contributor"},"id":"m1"},"usage":{"inputTokens":500,"outputTokens":100,"totalTokens":600,"cacheReadTokens":0}}}\n
        """
        try jsonl.write(to: transcriptFile, atomically: true, encoding: .utf8)

        // 2. Create projcache .json file for the same session
        let cacheDir = tempDir
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("\(sessionId).json")
        let cacheJson = """
        {"version":7,"record":{"identity":{"createdAt":1789320969837,"cwd":"\(projectFolder)"},"rows":{"tokenUsage":{"ver":2,"seq":2,"val":{"totals":{"uncachedInputTokens":500,"outputTokens":100,"cacheReadTokens":0,"cacheWriteTokens":0}}}}}}
        """
        try cacheJson.write(to: cacheFile, atomically: true, encoding: .utf8)

        let adapter = DshAdapter()

        // First pass: since: nil -> should return 1 record from transcript
        let first = try await adapter.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records[0].id, "dsh_\(sessionId)_2")
        XCTAssertEqual(first.records[0].inputTokens, 500)
        XCTAssertEqual(first.records[0].outputTokens, 100)
        XCTAssertEqual(first.records[0].sessionKey, sessionId)

        // Second pass: since: first.newCursor (transcript file size unchanged) -> MUST return 0 records (no projcache duplicate!)
        let second = try await adapter.fetchIncrementalRecords(from: tempDir, since: first.newCursor)
        XCTAssertEqual(second.records.count, 0)
    }
}
