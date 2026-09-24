import XCTest
import SQLite3
@testable import BennettUsageCore

final class CrushAdapterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testAdapterMetadataCatalogDisplayAndPalette() {
        let adapter = CrushAdapter()
        XCTAssertEqual(adapter.sourceId, "crush")
        XCTAssertEqual(adapter.displayName, "Crush")
        XCTAssertEqual(adapter.brandColorHex, "#E34D8A")
        XCTAssertEqual(adapter.defaultPath, "~/Library/Application Support/crush")
        XCTAssertEqual(AgentFilterBarView.displayName(for: "crush"), "Crush")
        XCTAssertNotNil(AppTheme.Agent.knownColor(for: "crush"))
        XCTAssertEqual(ChartPalette.shared.colors(for: ["crush"]).count, 1)
        XCTAssertTrue(AdapterCatalog.defaults.contains { $0 is CrushAdapter })
    }

    func testGlobalPathResolutionPriorityAndProjectsFileCompatibility() throws {
        let home = tempDir.appendingPathComponent("home")
        let explicit = tempDir.appendingPathComponent("explicit")
        XCTAssertEqual(
            CrushAdapter.resolveGlobalRoot(environment: ["CRUSH_GLOBAL_DATA": explicit.path], home: home),
            explicit.standardizedFileURL
        )
        let xdg = tempDir.appendingPathComponent("xdg")
        XCTAssertEqual(
            CrushAdapter.resolveGlobalRoot(environment: ["XDG_DATA_HOME": xdg.path], home: home).path,
            xdg.appendingPathComponent("crush").standardizedFileURL.path
        )
        XCTAssertEqual(
            CrushAdapter.resolveGlobalRoot(environment: ["XDG_DATA_HOME": xdg.path + "/CRUSH"], home: home).path,
            xdg.appendingPathComponent("CRUSH").standardizedFileURL.path
        )
        XCTAssertEqual(
            CrushAdapter.resolveGlobalRoot(environment: [:], home: home).path,
            home.appendingPathComponent("Library/Application Support/crush").standardizedFileURL.path
        )

        let uppercase = tempDir.appendingPathComponent("upper")
        try FileManager.default.createDirectory(at: uppercase.appendingPathComponent("CRUSH"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: uppercase.appendingPathComponent("CRUSH/projects.json"))
        XCTAssertTrue(CrushAdapter.projectsFileURL(under: uppercase).path
            .hasSuffix("/upper/CRUSH/projects.json"))
    }

    func testTwoProjectsWithSameDatabaseNameAndSessionIDStayIsolated() async throws {
        let global = tempDir.appendingPathComponent("global")
        let projectA = tempDir.appendingPathComponent("project-a")
        let projectB = tempDir.appendingPathComponent("project-b")
        let dataA = projectA.appendingPathComponent(".crush")
        let dataB = projectB.appendingPathComponent(".crush")
        try writeProjects(global, [
            (projectA.path, dataA.path), (projectB.path, dataB.path)
        ])
        try createDatabase(at: dataA, sessions: [session("shared", 10, 2, 0.1, 100, 90)])
        try createDatabase(at: dataB, sessions: [session("shared", 20, 4, 0.2, 100, 90)])

        let result = try await CrushAdapter().fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.records.map(\.projectFolder)), [projectA.path, projectB.path])
        XCTAssertEqual(Set(result.records.map(\.inputTokens)), [10, 20])
    }

    func testSymlinkAliasesImportOneDatabaseWithStableProjectMapping() async throws {
        let global = tempDir.appendingPathComponent("global")
        let data = tempDir.appendingPathComponent("data")
        let alias = tempDir.appendingPathComponent("data-alias")
        let projectA = tempDir.appendingPathComponent("project-a")
        let projectAlias = tempDir.appendingPathComponent("project-alias")
        let projectB = tempDir.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try createDatabase(at: data, sessions: [session("shared", 10, 2, 0.1, 100, 90)])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: data)
        try FileManager.default.createSymbolicLink(at: projectAlias, withDestinationURL: projectA)
        try writeProjects(global, [(projectAlias.path + "/", alias.path), (projectB.path, data.path)])

        let adapter = CrushAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.projectFolder, projectA.resolvingSymlinksInPath().path)
        XCTAssertEqual(adapter.auxiliaryWatchRoots(for: global), [data.standardizedFileURL])

        let repeated = try await adapter.fetchIncrementalRecords(from: global, since: result.newCursor)
        XCTAssertTrue(repeated.records.isEmpty, "aliases must not import the same physical database twice")
    }

    func testMissingDatabaseKeepsAggregateUntilRegistryEntryIsRemoved() async throws {
        let global = tempDir.appendingPathComponent("global")
        let projectA = tempDir.appendingPathComponent("project-a")
        let projectB = tempDir.appendingPathComponent("project-b")
        let dataA = projectA.appendingPathComponent(".crush")
        let dataB = projectB.appendingPathComponent(".crush")
        try writeProjects(global, [(projectA.path, dataA.path), (projectB.path, dataB.path)])
        try createDatabase(at: dataA, sessions: [session("a", 10, 2, 0.1, 100, 90)])
        try createDatabase(at: dataB, sessions: [session("b", 20, 4, 0.2, 100, 90)])

        let adapter = CrushAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(first.records.count, 2)
        try FileManager.default.removeItem(at: dataB)

        let temporarilyMissing = try await adapter.fetchIncrementalRecords(from: global, since: first.newCursor)
        XCTAssertTrue(temporarilyMissing.records.isEmpty)
        if case .databaseIdentity = temporarilyMissing.newCursor {
            XCTFail("a missing registered database must not cut over the source")
        }

        try writeProjects(global, [(projectA.path, dataA.path)])
        let removed = try await adapter.fetchIncrementalRecords(from: global, since: temporarilyMissing.newCursor)
        guard case .databaseIdentity = removed.newCursor else {
            return XCTFail("removing a registry entry must cut over the source")
        }
        let fresh = try await adapter.fetchIncrementalRecords(from: global, since: removed.newCursor)
        XCTAssertEqual(fresh.records.count, 1)
        XCTAssertEqual(fresh.records.first?.sessionKey, "a")
    }

    func testAuxiliaryWatchRootKeepsMissingDataDirUntilItIsCreated() async throws {
        let global = tempDir.appendingPathComponent("global")
        let data = tempDir.appendingPathComponent("not-created")
        let project = tempDir.appendingPathComponent("project")
        try writeProjects(global, [(project.path, data.path)])

        let adapter = CrushAdapter()
        XCTAssertEqual(adapter.auxiliaryWatchRoots(for: global), [data.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))

        try createDatabase(at: data, sessions: [session("created", 3, 1, 0.03, 100, 90)])
        let result = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.sessionKey, "created")
    }

    func testMissingProjectPathFallsBackToCanonicalDatabasePath() async throws {
        let global = tempDir.appendingPathComponent("global")
        let data = tempDir.appendingPathComponent("data")
        let alias = tempDir.appendingPathComponent("data-alias")
        try createDatabase(at: data, sessions: [session("fallback", 4, 2, 0.04, 100, 90)])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: data)
        try writeProjects(global, [("", alias.path)])

        let result = try await CrushAdapter().fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.first?.projectFolder, data.appendingPathComponent("crush.db").path)
    }

    func testRootProjectPathKeepsRootSeparator() async throws {
        let global = tempDir.appendingPathComponent("global")
        let data = tempDir.appendingPathComponent("data")
        try createDatabase(at: data, sessions: [session("root", 1, 1, 0.01, 100, 90)])
        try writeProjects(global, [("/", data.path)])

        let result = try await CrushAdapter().fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.first?.projectFolder, "/")
    }

    func testFirstRepeatSameSecondGrowthResetAndZeroCost() async throws {
        let global = tempDir.appendingPathComponent("global")
        let project = tempDir.appendingPathComponent("project")
        let data = project.appendingPathComponent(".crush")
        try writeProjects(global, [(project.path, data.path)])
        let database = data.appendingPathComponent("crush.db")
        try createDatabase(at: data, sessions: [
            session("top", 100, 20, 0, 1_000, 900),
            session("child", 999, 999, 9.99, 1_000, 900, parent: "top")
        ])

        let adapter = CrushAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(first.records.count, 1, "child sessions are excluded by default")
        let initial = try XCTUnwrap(first.records.first)
        XCTAssertEqual(initial.inputTokens, 100)
        XCTAssertEqual(initial.outputTokens, 20)
        XCTAssertEqual(initial.rawCostUSD, 0, "reported zero cost must be preserved")
        XCTAssertEqual(initial.model, "crush", "mixed message models cannot own a session total")

        let unchanged = try await adapter.fetchIncrementalRecords(from: global, since: first.newCursor)
        XCTAssertTrue(unchanged.records.isEmpty)

        // The cumulative change intentionally keeps the same second-level
        // updated_at value. The cumulative fingerprint makes the id unique.
        try updateSession(database, id: "top", prompt: 130, completion: 25, cost: 0, updated: 1_000)
        let sameSecond = try await adapter.fetchIncrementalRecords(from: global, since: unchanged.newCursor)
        XCTAssertEqual(sameSecond.records.count, 1)
        XCTAssertEqual(sameSecond.records.first?.inputTokens, 30)
        XCTAssertEqual(sameSecond.records.first?.outputTokens, 5)
        XCTAssertEqual(sameSecond.records.first?.rawCostUSD, 0)
        XCTAssertNotEqual(sameSecond.records.first?.id, initial.id)

        try updateSession(database, id: "top", prompt: 2, completion: 1, cost: 0.25, updated: 1_001)
        let reset = try await adapter.fetchIncrementalRecords(from: global, since: sameSecond.newCursor)
        XCTAssertEqual(reset.records.count, 1)
        XCTAssertEqual(reset.records.first?.inputTokens, 2, "a decrease starts a full generation snapshot")
        XCTAssertEqual(reset.records.first?.outputTokens, 1)
        XCTAssertEqual(reset.records.first?.rawCostUSD, 0.25)
        XCTAssertTrue(reset.records[0].inputTokens >= 0)
        XCTAssertTrue(reset.records[0].outputTokens >= 0)
        XCTAssertTrue((reset.records[0].rawCostUSD ?? -1) >= 0)
        XCTAssertTrue(reset.records[0].id.contains(":g1:"))
    }

    func testDatabaseReplacementReturnsCutoverCursorThenFreshSnapshot() async throws {
        let global = tempDir.appendingPathComponent("global")
        let project = tempDir.appendingPathComponent("project")
        let data = project.appendingPathComponent(".crush")
        try writeProjects(global, [(project.path, data.path)])
        let database = data.appendingPathComponent("crush.db")
        try createDatabase(at: data, sessions: [session("s", 10, 1, 0.1, 100, 90)])

        let adapter = CrushAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        let replacementData = tempDir.appendingPathComponent("replacement")
        try createDatabase(at: replacementData, sessions: [session("s", 7, 2, 0.07, 200, 190)])
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: replacementData.appendingPathComponent("crush.db"), to: database)

        let cutover = try await adapter.fetchIncrementalRecords(from: global, since: first.newCursor)
        XCTAssertTrue(cutover.records.isEmpty, "records are withheld until SyncCoordinator cuts over")
        guard case .databaseIdentity = cutover.newCursor else {
            return XCTFail("replacement must use the existing databaseIdentity cutover")
        }
        let fresh = try await adapter.fetchIncrementalRecords(from: global, since: cutover.newCursor)
        XCTAssertEqual(fresh.records.count, 1)
        XCTAssertEqual(fresh.records.first?.inputTokens, 7)
        XCTAssertTrue(fresh.records[0].id.contains(":g0:"))
    }

    func testWALDatabaseIsReadWithoutChangingDatabaseOrWALBytes() async throws {
        let global = tempDir.appendingPathComponent("global")
        let project = tempDir.appendingPathComponent("project")
        let data = project.appendingPathComponent(".crush")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try writeProjects(global, [(project.path, data.path)])
        let databaseURL = data.appendingPathComponent("crush.db")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(writer) }
        try execute(writer, "PRAGMA journal_mode=WAL;")
        try execute(writer, "PRAGMA wal_autocheckpoint=0;")
        try execute(writer, Self.schemaSQL)
        try execute(writer, Self.insertSQL)
        let databaseBefore = try Data(contentsOf: databaseURL)
        let walBefore = try Data(contentsOf: data.appendingPathComponent("crush.db-wal"))

        let result = try await CrushAdapter().fetchIncrementalRecords(from: global, since: nil)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("crush.db-wal")), walBefore)
    }

    func testMissingBadAndPartiallyMissingProjectRegistryDoNotCrash() async throws {
        let adapter = CrushAdapter()
        let missingRoot = tempDir.appendingPathComponent("missing")
        let missing = try await adapter.fetchIncrementalRecords(from: missingRoot, since: nil)
        XCTAssertTrue(missing.records.isEmpty)
        XCTAssertTrue(adapter.auxiliaryWatchRoots(for: missingRoot).isEmpty)

        let global = tempDir.appendingPathComponent("global")
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: global.appendingPathComponent("projects.json"))
        let bad = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        XCTAssertTrue(bad.records.isEmpty)

        let present = tempDir.appendingPathComponent("present")
        let absent = tempDir.appendingPathComponent("absent")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try writeProjects(global, [(tempDir.appendingPathComponent("present-project").path, present.path),
                                  (tempDir.appendingPathComponent("absent-project").path, absent.path)])
        try createDatabase(at: present, sessions: [session("s", 1, 1, 0, 10, 9)])
        XCTAssertEqual(adapter.auxiliaryWatchRoots(for: global), [present.standardizedFileURL, absent.standardizedFileURL])
        let partial = try await adapter.fetchIncrementalRecords(from: global, since: bad.newCursor)
        XCTAssertEqual(partial.records.count, 1)
    }

    func testDeletingSessionDoesNotEmitNegativeRecord() async throws {
        let global = tempDir.appendingPathComponent("global")
        let data = tempDir.appendingPathComponent("data")
        try writeProjects(global, [(tempDir.appendingPathComponent("project").path, data.path)])
        try createDatabase(at: data, sessions: [session("s", 10, 2, 0.2, 100, 90)])
        let adapter = CrushAdapter()
        let first = try await adapter.fetchIncrementalRecords(from: global, since: nil)
        try execute(data.appendingPathComponent("crush.db"), "DELETE FROM sessions WHERE id='s';")
        let deleted = try await adapter.fetchIncrementalRecords(from: global, since: first.newCursor)
        XCTAssertTrue(deleted.records.isEmpty, "append-only storage cannot represent a session deletion")
    }

    // MARK: - Fixtures

    private static let schemaSQL = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL,
            cost REAL NOT NULL, updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, session_id TEXT, role TEXT, model TEXT
        );
        """

    private static let insertSQL = """
        INSERT INTO sessions
        (id,parent_session_id,title,prompt_tokens,completion_tokens,cost,updated_at,created_at)
        VALUES ('s',NULL,'Session',10,2,0.125,1000,900);
        INSERT INTO messages VALUES
        ('m1','s','assistant','model-a'),('m2','s','assistant','model-b');
        """

    private func writeProjects(_ global: URL, _ projects: [(String, String)]) throws {
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let entries = projects.map { ["path": $0.0, "data_dir": $0.1] }
        let data = try JSONSerialization.data(withJSONObject: ["projects": entries])
        try data.write(to: global.appendingPathComponent("projects.json"))
    }

    private func session(
        _ id: String, _ prompt: Int64, _ completion: Int64, _ cost: Double,
        _ updated: Int64, _ created: Int64, parent: String? = nil
    ) -> (String, String?, Int64, Int64, Double, Int64, Int64) {
        (id, parent, prompt, completion, cost, updated, created)
    }

    private func createDatabase(
        at dataDirectory: URL,
        sessions: [(String, String?, Int64, Int64, Double, Int64, Int64)]
    ) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let database = dataDirectory.appendingPathComponent("crush.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        try execute(handle, Self.schemaSQL)
        for (id, parent, prompt, completion, cost, updated, created) in sessions {
            try execute(handle, """
                INSERT INTO sessions
                (id,parent_session_id,title,prompt_tokens,completion_tokens,cost,updated_at,created_at)
                VALUES ('\(sqlString(id))',\(parent.map { "'\(sqlString($0))'" } ?? "NULL"),'Session',\(prompt),\(completion),\(cost),\(updated),\(created));
                """)
        }
    }

    private func updateSession(
        _ database: URL, id: String, prompt: Int64, completion: Int64, cost: Double, updated: Int64
    ) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        try execute(handle, """
            UPDATE sessions SET prompt_tokens=\(prompt), completion_tokens=\(completion),
            cost=\(cost), updated_at=\(updated) WHERE id='\(sqlString(id))';
            """)
    }

    private func execute(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        try execute(handle, sql)
    }

    private func execute(_ handle: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? sql)
        sqlite3_free(error)
    }

    private func sqlString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
