import XCTest
import SQLite3
@testable import BennettUsageCore

// The SQLite3 system module does not expose SQLITE_TRANSIENT to Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AntigravityAdapterTests: XCTestCase {
    var tempDir: URL!
    var conversationsDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        conversationsDir = tempDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Protobuf fixture builders

    private func varintBytes(_ v: UInt64) -> [UInt8] {
        var value = v
        var out: [UInt8] = []
        while true {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
            if value == 0 { break }
        }
        return out
    }

    private func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        varintBytes(UInt64(number) << 3 | 0) + varintBytes(value)
    }

    private func bytesField(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varintBytes(UInt64(number) << 3 | 2) + varintBytes(UInt64(bytes.count)) + bytes
    }

    /// Metadata blob for a model-response step: timestamp submsg (field 1)
    /// + usage submsg (field 9: 2=uncached input, 3=output, 5=cached input).
    private func stepMetadata(seconds: UInt64, nanos: UInt64, input: UInt64, output: UInt64, cached: UInt64) -> [UInt8] {
        let ts = bytesField(1, varintField(1, seconds) + varintField(2, nanos))
        var usage = varintField(2, input) + varintField(3, output)
        if cached > 0 { usage += varintField(5, cached) }
        return ts + bytesField(9, usage)
    }

    /// gen_metadata blob: field 1 submsg carrying the model name at field 19.
    private func genMetadata(model: String) -> [UInt8] {
        bytesField(1, bytesField(19, Array(model.utf8)))
    }


    private func makeConversationDB(
        at url: URL,
        steps: [(idx: Int32, metadata: [UInt8])],
        models: [String]
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw XCTSkip("Could not create fixture database")
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
        CREATE TABLE steps (
            idx INTEGER PRIMARY KEY,
            step_type INTEGER NOT NULL DEFAULT 0,
            status INTEGER NOT NULL DEFAULT 0,
            metadata BLOB,
            step_payload BLOB
        );
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        """, nil, nil, nil)

        for step in steps {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, metadata) VALUES (?, 15, ?)", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, step.idx)
            step.metadata.withUnsafeBufferPointer { buf in
                _ = sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(step.metadata.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        for (i, model) in models.enumerated() {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(i))
            let blob = genMetadata(model: model)
            blob.withUnsafeBufferPointer { buf in
                _ = sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Tests

    func testAdapterMetadata() {
        let adapter = AntigravityAdapter()
        XCTAssertEqual(adapter.sourceId, "antigravity")
        XCTAssertEqual(adapter.displayName, "Antigravity")
        XCTAssertEqual(adapter.defaultPath, "~/.gemini/antigravity/conversations")
    }

    func testDefaultPathFromProtocolExtension() {
        XCTAssertEqual(AntigravityAdapter().defaultPath, "~/.gemini/antigravity/conversations")
    }

    func testFetchFromEmptyDirectoryReturnsEmpty() async throws {
        let adapter = AntigravityAdapter()
        let (records, cursor) = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        XCTAssertTrue(records.isEmpty)
        if case .fileOffsets = cursor {} else {
            XCTFail("Expected fileOffsets cursor")
        }
    }

    func testParsesModelResponseSteps() async throws {
        let dbUrl = conversationsDir.appendingPathComponent("ee44613e-53bf-4f3c-b74c-a072b5816351.db")
        try makeConversationDB(
            at: dbUrl,
            steps: [
                (1, stepMetadata(seconds: 1_788_883_126, nanos: 282_131_000, input: 15_636, output: 1_618, cached: 0)),
                (3, stepMetadata(seconds: 1_788_883_165, nanos: 529_249_000, input: 9_222, output: 372, cached: 8_137)),
            ],
            models: ["gemini-3.7-flash", "gemini-3.8-flash"]
        )

        let adapter = AntigravityAdapter()
        let (records, _) = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)

        XCTAssertEqual(records.count, 2)

        let first = records[0]
        XCTAssertEqual(first.sourceId, "antigravity")
        XCTAssertEqual(first.sessionKey, "ee44613e-53bf-4f3c-b74c-a072b5816351")
        XCTAssertEqual(first.inputTokens, 15_636)
        XCTAssertEqual(first.outputTokens, 1_618)
        XCTAssertEqual(first.cacheReadTokens, 0)
        XCTAssertEqual(first.model, "gemini-3.7-flash")
        XCTAssertEqual(first.id, "antigravity_ee44613e-53bf-4f3c-b74c-a072b5816351_1")
        XCTAssertEqual(
            first.timestamp.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_788_883_126.282131).timeIntervalSince1970,
            accuracy: 0.001
        )

        let second = records[1]
        XCTAssertEqual(second.inputTokens, 9_222)
        XCTAssertEqual(second.cacheReadTokens, 8_137)
        XCTAssertEqual(second.totalTokens, 9_222 + 372 + 8_137)
        XCTAssertEqual(second.model, "gemini-3.8-flash")
    }

    func testIdsAreStableAcrossRefetches() async throws {
        let dbUrl = conversationsDir.appendingPathComponent("abc.db")
        try makeConversationDB(
            at: dbUrl,
            steps: [(5, stepMetadata(seconds: 1_788_883_126, nanos: 0, input: 100, output: 50, cached: 0))],
            models: ["gemini-3.7-flash"]
        )

        let adapter = AntigravityAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        let second = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        XCTAssertEqual(first.records.map(\.id), second.records.map(\.id))
    }

    func testSkipsMalformedMetadataWithoutCrashing() async throws {
        let dbUrl = conversationsDir.appendingPathComponent("bad.db")
        try makeConversationDB(
            at: dbUrl,
            steps: [
                (1, [0xFF, 0xFF, 0xFF, 0xFF]), // malformed protobuf
                (3, stepMetadata(seconds: 1_788_883_126, nanos: 0, input: 500, output: 100, cached: 0)),
            ],
            models: ["gemini-3.7-flash"]
        )

        let adapter = AntigravityAdapter()
        let (records, _) = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 500)
    }

    func testIgnoresNonModelStepsAndForeignFiles() async throws {
        let dbUrl = conversationsDir.appendingPathComponent("mix.db")
        // steps table containing a tool-call step (type 132) and a model step (15)
        var db: OpaquePointer?
        sqlite3_open(dbUrl.path, &db)
        sqlite3_exec(db, """
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0, status INTEGER NOT NULL DEFAULT 0, metadata BLOB, step_payload BLOB);
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        """, nil, nil, nil)
        let good = stepMetadata(seconds: 1_788_883_126, nanos: 0, input: 42, output: 7, cached: 0)
        good.withUnsafeBufferPointer { buf in
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, metadata) VALUES (1, 132, ?)", -1, &stmt, nil)
            _ = sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(good.count), SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, metadata) VALUES (2, 15, ?)", -1, &stmt, nil)
            _ = sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(good.count), SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)

        // Unrelated file that must be ignored entirely.
        try Data([0x00, 0x01]).write(to: conversationsDir.appendingPathComponent("notes.txt"))

        let adapter = AntigravityAdapter()
        let (records, _) = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inputTokens, 42)
        XCTAssertEqual(records[0].outputTokens, 7)
    }

    func testMissingGenMetadataFallsBackToGenericModel() async throws {
        let dbUrl = conversationsDir.appendingPathComponent("nomodel.db")
        try makeConversationDB(
            at: dbUrl,
            steps: [(1, stepMetadata(seconds: 1_788_883_126, nanos: 0, input: 10, output: 5, cached: 0))],
            models: []
        )

        let adapter = AntigravityAdapter()
        let (records, _) = try await adapter.fetchIncrementalRecords(from: conversationsDir, since: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "gemini")
    }
}
