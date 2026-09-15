import XCTest
@testable import BennettUsageCore

/// Live smoke test against the developer's own `~/.cline` (or `$CLINE_DIR` /
/// `$CLINE_DATA_DIR` / `$CLINE_SESSION_DATA_DIR`). Passes vacuously on
/// machines without Cline's standalone runtime installed.
final class ClineLiveValidationTests: XCTestCase {
    func testLiveClineSessions() async throws {
        let sessions = ClineAdapter.sessionsRoot()
        guard FileManager.default.fileExists(atPath: sessions.path) else { return }

        let adapter = ClineAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: sessions, since: nil)

        let realSessions = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
            .filter { !$0.hasPrefix(".") }
        guard !realSessions.isEmpty else { return }

        XCTAssertGreaterThan(result.records.count, 0, "expected live Cline records")
        for record in result.records {
            XCTAssertFalse(record.sessionKey.isEmpty)
            XCTAssertGreaterThan(record.totalTokens, 0)
            // The tool name must never leak in as a model (the DSH lesson).
            XCTAssertNotEqual(record.model, "cline")
        }
        // A canonical transcript carries a real provider/model id; only the
        // optional app-stream fallback can be model-less.
        XCTAssertTrue(result.records.contains { $0.model != "unknown" },
                      "expected transcript records with real model names")
    }

    /// End-to-end through the coordinator: the first pass persists what the
    /// adapter parsed, and re-syncing the same (unchanged) sessions must not
    /// double count.
    func testLiveClineSyncIsIdempotent() async throws {
        let sessions = ClineAdapter.sessionsRoot()
        guard FileManager.default.fileExists(atPath: sessions.path) else { return }
        let adapter = ClineAdapter()
        let parsed = try await adapter.fetchIncrementalRecords(from: sessions, since: nil)
        guard !parsed.records.isEmpty else { return }

        let database = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        registry.register(adapter)
        let coordinator = SyncCoordinator(database: database, registry: registry)

        let first = try await coordinator.syncAll()
        XCTAssertEqual(first, parsed.records.count)
        let second = try await coordinator.syncAll()
        XCTAssertEqual(second, 0, "re-syncing unchanged Cline sessions must not double count")

        let stats = try database.fetchRecordStats(forSourceId: "cline")
        XCTAssertEqual(stats.count, parsed.records.count)
        let totals = try database.fetchAllTimeTotals(sourceId: "cline")
        XCTAssertEqual(totals.totalTokens, parsed.records.reduce(0) { $0 + $1.totalTokens })
    }
}
