import XCTest
@testable import BennettUsageCore

final class EndToEndSmokeTests: XCTestCase {
    func testRealEnvironmentDetectionAndSync() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let omp = OmpAdapter()
        let pi = PiAdapter()
        if omp.detectDefaultPath() == nil && pi.detectDefaultPath() == nil {
            throw XCTSkip("No local agent store found on this machine")
        }
        registry.register(omp)
        registry.register(pi)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let ingested = try await coordinator.syncAll()
        
        let aggregator = MetricsAggregator(database: db)
        let heatmap = try await aggregator.fetchAnnualHeatmap(year: 2026)
        
        XCTAssertGreaterThan(ingested, 0, "Expected to ingest real records from local ~/.omp or ~/.pi")
        XCTAssertGreaterThan(heatmap.count, 0)
        XCTAssertFalse(heatmap.contains { $0.date > Date() }, "Annual heatmap must not include future days")
        XCTAssertTrue(heatmap.contains { $0.totalTokens > 0 }, "Expected at least one day in heatmap with totalTokens > 0")
        print("Successfully synced \(ingested) real records from local environment.")
    }
}
