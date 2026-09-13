import XCTest
@testable import BennettUsageCore

/// Live smoke test against the developer's own `~/.dsh` (or `$DSH_HOME`).
/// Passes vacuously on machines without DSH sessions; validates the zstd
/// transcript path end to end where the harness actually runs.
final class DshLiveValidationTests: XCTestCase {
    func testLiveDshSessions() async throws {
        let home = DshAdapter.resolveHome()
        let sessions = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else { return }
        guard DshAdapter.zstdExecutable() != nil else { return }
        let adapter = DshAdapter()
        let result = try await adapter.fetchIncrementalRecords(from: sessions, since: nil)
        XCTAssertGreaterThan(result.records.count, 0, "expected live DSH records")
        // Transcript path must win wherever zstd decodes: at least one record
        // carries a real model name rather than the projcache "dsh" fallback.
        XCTAssertTrue(result.records.contains { $0.model != "dsh" },
                      "expected per-step transcript records with real model names")
    }
}
