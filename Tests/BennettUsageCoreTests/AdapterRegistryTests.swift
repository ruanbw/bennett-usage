import XCTest
@testable import BennettUsageCore

final class MockAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String = "mock"
    let displayName: String = "Mock Tool"
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"
    
    func detectDefaultPath() -> URL? { nil }
    func fetchIncrementalRecords(from directory: URL, since cursor: SyncCursor?) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        return ([], .rowId(1))
    }
}

final class AdapterRegistryTests: XCTestCase {
    func testRegisterAndRetrieveAdapter() {
        let registry = AdapterRegistry()
        let mock = MockAdapter()
        registry.register(mock)
        
        let retrieved = registry.get(sourceId: "mock")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "Mock Tool")
        XCTAssertEqual(registry.allAdapters().count, 1)
    }
}
