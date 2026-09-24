import Darwin
import XCTest
@testable import BennettUsageCore

final class KimiCodeAdapterTests: XCTestCase {
    private var home: URL!
    private var sessions: URL!
    private var mainWire: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-code-\(UUID().uuidString)", isDirectory: true)
        sessions = home.appendingPathComponent("sessions", isDirectory: true)
        mainWire = try wireURL(agentPath: "main")
        try FileManager.default.createDirectory(
            at: mainWire.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @MainActor
    func testMetadataCatalogDisplayNameAndPalette() {
        let adapter = KimiCodeAdapter()
        XCTAssertEqual(adapter.sourceId, "kimi")
        XCTAssertEqual(adapter.displayName, "Kimi Code")
        XCTAssertEqual(adapter.defaultPath, "~/.kimi-code")
        XCTAssertEqual(adapter.syncRootPath, KimiCodeAdapter.resolvedSessionsRoot().path)
        XCTAssertFalse(adapter.isSyncStub)
        XCTAssertTrue(AdapterCatalog.defaults.contains { $0 is KimiCodeAdapter })
        XCTAssertEqual(AgentFilterBarView.displayName(for: "KIMI"), "Kimi Code")
        XCTAssertTrue(AppTheme.Agent.knownColor(for: "kimi") != nil)
        XCTAssertNotNil(AppTheme.Agent.allMap["kimi"])
        let palette = AgentFilterBarView.colorMap
        XCTAssertNotNil(palette["kimi"])
    }

    func testReadsMainAndSubagentWiresWithPathDerivedSessionKey() async throws {
        let subagentWire = try wireURL(agentPath: "agents/subagent-7")
        try FileManager.default.createDirectory(
            at: subagentWire.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(
            mainWire,
            lines: [usage(agentId: "main", scope: "turn", time: 1_700_000_000_123)]
        )
        try write(
            subagentWire,
            lines: [usage(agentId: "subagent-7", scope: "turn", time: 1_700_000_001_456)]
        )

        let result = try await KimiCodeAdapter().fetchIncrementalRecords(from: home, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.map(\.sessionKey)), ["--work-a--/session-1"])
        XCTAssertEqual(Set(result.records.map(\.model)), ["kimi-k2"])
        XCTAssertTrue(result.records.allSatisfy { $0.projectFolder == nil })
    }

    func testImportsBothTurnAndSessionAsIndependentIncrements() async throws {
        try write(mainWire, lines: [
            usage(agentId: "main", scope: "turn", time: 1_700_000_000_000, input: 10, output: 2, read: 30, creation: 4),
            usage(agentId: "main", scope: "session", time: 1_700_000_001_000, input: 20, output: 3, read: 40, creation: 5),
        ])

        let records = try await KimiCodeAdapter().fetchIncrementalRecords(from: home, since: nil).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.inputTokens), [10, 20])
        XCTAssertEqual(records.reduce(0) { $0 + $1.inputTokens }, 30)
        XCTAssertEqual(records.reduce(0) { $0 + $1.outputTokens }, 5)
        XCTAssertEqual(records.reduce(0) { $0 + $1.cacheReadTokens }, 70)
        XCTAssertEqual(records.reduce(0) { $0 + $1.cacheWriteTokens }, 9)
    }

    func testIgnoresUnknownFieldsInsteadOfGuessingMetadata() async throws {
        var payload = usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)
        payload["provider"] = "invented-provider"
        payload["costUSD"] = 123.45
        payload["reasoningTokens"] = 999
        payload["requestId"] = "invented-request"
        payload["raw"] = ["provider": "also-invented"]
        try write(mainWire, lines: [payload])

        let result = try await KimiCodeAdapter().fetchIncrementalRecords(from: home, since: nil)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertNil(record.provider)
        XCTAssertNil(record.projectFolder)
        XCTAssertNil(record.rawCostUSD)
        XCTAssertEqual(record.outputTokens, 2)
    }

    func testOnlyConsumesCompleteLinesAndThenResumesAtCommittedOffset() async throws {
        let first = usage(agentId: "main", scope: "turn", time: 1_700_000_000_000, output: 2)
        let second = usage(agentId: "main", scope: "session", time: 1_700_000_001_000, output: 3)
        let complete = try jsonLine(first)
        let truncated = try jsonLine(second)
        try Data((complete + String(truncated.prefix(30))).utf8).write(to: mainWire)

        let adapter = KimiCodeAdapter()
        let initial = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        XCTAssertEqual(initial.records.count, 1)
        guard case .fileGenerations(let firstFiles) = initial.newCursor,
              let firstCheckpoint = firstFiles[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }
        XCTAssertEqual(firstCheckpoint.offset, Int64(complete.utf8.count))
        XCTAssertGreaterThan(firstCheckpoint.size, firstCheckpoint.offset)

        let handle = try FileHandle(forWritingTo: mainWire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(truncated.dropFirst(30)).utf8))
        try handle.close()
        let resumed = try await adapter.fetchIncrementalRecords(from: home, since: initial.newCursor)
        XCTAssertEqual(resumed.records.count, 1)
        XCTAssertEqual(resumed.records[0].outputTokens, 3)
        guard case .fileGenerations(let resumedFiles) = resumed.newCursor,
              let resumedCheckpoint = resumedFiles[mainWire.path] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }
        XCTAssertEqual(resumedCheckpoint.generation, firstCheckpoint.generation)
        XCTAssertNotEqual(resumedCheckpoint.prefixHash, firstCheckpoint.prefixHash)
        XCTAssertEqual(resumedCheckpoint.offset, Int64((complete + truncated).utf8.count))
        XCTAssertEqual(resumedCheckpoint.size, resumedCheckpoint.offset)
    }

    func testIdenticalPayloadAtDifferentOffsetsGetsDistinctRecordIDs() async throws {
        let payload = usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)
        try write(mainWire, lines: [payload, payload])

        let records = try await KimiCodeAdapter().fetchIncrementalRecords(from: home, since: nil).records
        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(records[0].id, records[1].id)
    }

    func testRepeatedScanReturnsNoRecords() async throws {
        try write(mainWire, lines: [usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)])
        let adapter = KimiCodeAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        let second = try await adapter.fetchIncrementalRecords(from: home, since: first.newCursor)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertEqual(first.newCursor, second.newCursor)
    }

    func testTruncationOrPrefixRewriteChangesConsumedHash() async throws {
        try write(mainWire, lines: [
            usage(agentId: "main", scope: "turn", time: 1_700_000_000_000, output: 2),
            usage(agentId: "main", scope: "turn", time: 1_700_000_001_000, output: 3),
        ])
        let adapter = KimiCodeAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        guard case .fileGenerations(let firstFiles) = first.newCursor,
              let firstCheckpoint = firstFiles[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }

        try write(mainWire, lines: [usage(agentId: "main", scope: "session", time: 1_700_000_002_000, output: 7)])
        let rewritten = try await adapter.fetchIncrementalRecords(from: home, since: first.newCursor)
        guard case .fileGenerations(let rewrittenFiles) = rewritten.newCursor,
              let rewrittenCheckpoint = rewrittenFiles[mainWire.path] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }
        XCTAssertEqual(rewrittenCheckpoint.generation, firstCheckpoint.generation)
        XCTAssertNotEqual(rewrittenCheckpoint.prefixHash, firstCheckpoint.prefixHash)
        XCTAssertEqual(rewritten.records.count, 1)
        XCTAssertEqual(rewritten.records[0].outputTokens, 7)
    }

    func testSecondLineRewriteWithUnchangedFirstLineAndMetadataRescansConsumedPrefix() async throws {
        let first = usage(agentId: "main", scope: "turn", time: 1_700_000_000_000, output: 2)
        let second = usage(agentId: "main", scope: "turn", time: 1_700_000_001_000, output: 3)
        let firstLine = try jsonLine(first)
        try Data((firstLine + jsonLine(second)).utf8).write(to: mainWire)

        let adapter = KimiCodeAdapter()
        let initial = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        guard case .fileGenerations(let initialFiles) = initial.newCursor,
              let initialCheckpoint = initialFiles[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }
        let initialStat = try fileStat(mainWire)
        let initialModificationDate = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: mainWire.path)[.modificationDate] as? Date
        )

        let rewrittenSecond = usage(agentId: "main", scope: "turn", time: 1_700_000_001_000, output: 9)
        try Data((firstLine + jsonLine(rewrittenSecond)).utf8).write(to: mainWire)
        try FileManager.default.setAttributes(
            [.modificationDate: initialModificationDate],
            ofItemAtPath: mainWire.path
        )
        let rewrittenStat = try fileStat(mainWire)
        let rewrittenData = try Data(contentsOf: mainWire)
        XCTAssertEqual(
            String(decoding: rewrittenData.prefix(firstLine.utf8.count), as: UTF8.self),
            firstLine
        )

        XCTAssertEqual(rewrittenStat.identity, initialStat.identity)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: mainWire.path)[.modificationDate] as? Date,
            initialModificationDate
        )
        let rescanned = try await adapter.fetchIncrementalRecords(from: home, since: initial.newCursor)
        XCTAssertEqual(rescanned.records.count, 2)
        XCTAssertEqual(rescanned.records.map(\.outputTokens), [2, 9])
        guard case .fileGenerations(let files) = rescanned.newCursor,
              let checkpoint = files[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }
        XCTAssertNotEqual(checkpoint.prefixHash, initialCheckpoint.prefixHash)
    }

    func testLegacyCursorWithoutPrefixHashRescansOnce() async throws {
        try write(mainWire, lines: [
            usage(agentId: "main", scope: "turn", time: 1_700_000_000_000, output: 2),
            usage(agentId: "main", scope: "turn", time: 1_700_000_001_000, output: 3),
        ])
        let adapter = KimiCodeAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        guard case .fileGenerations(let firstFiles) = first.newCursor,
              let checkpoint = firstFiles[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a Kimi file-generation checkpoint")
        }

        let legacyCursor = SyncCursor.fileGenerations([
            KimiCodeAdapter.canonicalPath(for: mainWire): FileGeneration(
                generation: checkpoint.generation,
                offset: checkpoint.offset,
                size: checkpoint.size
            ),
        ])
        let migrated = try await adapter.fetchIncrementalRecords(from: home, since: legacyCursor)
        XCTAssertEqual(migrated.records.count, 2)
        guard case .fileGenerations(let migratedFiles) = migrated.newCursor,
              let migratedCheckpoint = migratedFiles[KimiCodeAdapter.canonicalPath(for: mainWire)] else {
            return XCTFail("Expected a migrated Kimi file-generation checkpoint")
        }
        XCTAssertNotNil(migratedCheckpoint.prefixHash)
        XCTAssertNotEqual(migrated.newCursor, legacyCursor)

        let repeated = try await adapter.fetchIncrementalRecords(from: home, since: migrated.newCursor)
        XCTAssertTrue(repeated.records.isEmpty)
    }

    func testMalformedCompleteLinePreservesOldCheckpoint() async throws {
        let valid = usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)
        try write(mainWire, lines: [valid])
        let adapter = KimiCodeAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: home, since: nil)

        let validLine = try jsonLine(valid)
        try Data((validLine + "{not-json}\n").utf8).write(to: mainWire)
        let malformed = try await adapter.fetchIncrementalRecords(from: home, since: first.newCursor)
        XCTAssertTrue(malformed.records.isEmpty)
        XCTAssertEqual(malformed.newCursor, first.newCursor)
    }

    func testDeletingWireRemovesCheckpointWithoutNegativeRecord() async throws {
        try write(mainWire, lines: [usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)])
        let adapter = KimiCodeAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        XCTAssertEqual(first.records.count, 1)

        try FileManager.default.removeItem(at: mainWire)
        let deleted = try await adapter.fetchIncrementalRecords(from: home, since: first.newCursor)
        XCTAssertTrue(deleted.records.isEmpty)
        XCTAssertEqual(deleted.newCursor, .fileGenerations([:]))
    }

    func testScansOnlyOfficialCurrentWirePaths() async throws {
        try write(mainWire, lines: [usage(agentId: "main", scope: "turn", time: 1_700_000_000_000)])
        let wrongTree = home.appendingPathComponent("sessions/work/session-1/other/wire.jsonl")
        try FileManager.default.createDirectory(at: wrongTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(wrongTree, lines: [usage(agentId: "wrong", scope: "turn", time: 1_700_000_000_000)])
        let backup = mainWire.appendingPathExtension("bak")
        try write(backup, lines: [usage(agentId: "backup", scope: "turn", time: 1_700_000_000_000)])
        let legacy = home.deletingLastPathComponent().appendingPathComponent(".kimi/context.jsonl")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(legacy, lines: [usage(agentId: "legacy", scope: "turn", time: 1_700_000_000_000)])

        let records = try await KimiCodeAdapter().fetchIncrementalRecords(from: home, since: nil).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "kimi-k2")
        try? FileManager.default.removeItem(at: legacy)
    }

    func testCompleteSnapshotRejectsUnavailableRootAndMalformedCompleteLine() async throws {
        let adapter = KimiCodeAdapter()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-kimi-\(UUID().uuidString)", isDirectory: true)

        let incremental = try await adapter.fetchIncrementalRecords(from: missing, since: nil)
        XCTAssertTrue(incremental.records.isEmpty)
        do {
            _ = try await adapter.fetchCompleteSnapshot(from: missing)
            XCTFail("A cutover snapshot must reject an unavailable sessions root")
        } catch {}

        try Data("{not-json}\n".utf8).write(to: mainWire)
        let lenient = try await adapter.fetchIncrementalRecords(from: home, since: nil)
        XCTAssertTrue(lenient.records.isEmpty)
        do {
            _ = try await adapter.fetchCompleteSnapshot(from: home)
            XCTFail("A cutover snapshot must reject a malformed complete JSONL line")
        } catch {}
    }

    func testCompleteSnapshotAllowsTruncatedFinalLine() async throws {
        let valid = try jsonLine(usage(
            agentId: "main",
            scope: "turn",
            time: 1_700_000_000_000
        ))
        try Data((valid + "{\"type\":\"usage.record\"").utf8).write(to: mainWire)

        let result = try await KimiCodeAdapter().fetchCompleteSnapshot(from: home)

        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.outputTokens, 2)
    }

    func testKimiCodeHomeOverrideAndDefaultResolution() {
        let userHome = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let defaultRoot = KimiCodeAdapter.resolvedHome(environment: [:], homeDirectory: userHome)
        let defaultSessions = KimiCodeAdapter.resolvedSessionsRoot(environment: [:], homeDirectory: userHome)
        XCTAssertEqual(defaultRoot.path, "/Users/test/.kimi-code")
        XCTAssertEqual(defaultSessions.path, "/Users/test/.kimi-code/sessions")

        let overridden = KimiCodeAdapter.resolvedSessionsRoot(
            environment: ["KIMI_CODE_HOME": " /Volumes/KimiData "],
            homeDirectory: userHome
        )
        XCTAssertEqual(overridden.path, "/Volumes/KimiData/sessions")
    }

    private func wireURL(agentPath: String) throws -> URL {
        sessions
            .appendingPathComponent("--work-a--", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentPath, isDirectory: true)
            .appendingPathComponent("wire.jsonl")
    }

    private func write(_ url: URL, lines: [[String: Any]]) throws {
        let text = try lines.map(jsonLine).joined()
        try Data(text.utf8).write(to: url)
    }

    private struct FileStat {
        let identity: String
    }

    private func fileStat(_ url: URL) throws -> FileStat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return FileStat(identity: "\(info.st_dev):\(info.st_ino)")
    }

    private func jsonLine(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func usage(
        agentId: String,
        scope: String,
        time: Int64,
        input: Int = 1,
        output: Int = 2,
        read: Int = 3,
        creation: Int = 4
    ) -> [String: Any] {
        [
            "type": "usage.record",
            "time": time,
            "agentId": agentId,
            "model": "kimi-k2",
            "usageScope": scope,
            "usage": [
                "inputOther": input,
                "output": output,
                "inputCacheRead": read,
                "inputCacheCreation": creation,
            ],
        ]
    }
}
