import XCTest
@testable import BennettUsageCore

final class EndToEndSmokeTests: XCTestCase {
    func testRealEnvironmentDetectionAndSync() async throws {
        let db = try DatabaseManager.inMemory()
        let registry = AdapterRegistry()
        let omp = OmpAdapter()
        let pi = PiAdapter()
        registry.register(omp)
        registry.register(pi)

        let coordinator = SyncCoordinator(database: db, registry: registry)
        let ingested = try await coordinator.syncAll()
        
        let aggregator = MetricsAggregator(database: db)
        let heatmap = try await aggregator.fetchAnnualHeatmap(year: 2026)
        
        XCTAssertTrue(heatmap.count >= 365)
        print("Successfully synced \(ingested) real records from local environment.")
    }
}
