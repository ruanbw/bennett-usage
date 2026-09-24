import XCTest
@testable import BennettUsageCore

final class MockAdapter: AgentSourceAdapter, @unchecked Sendable {
    let sourceId: String
    let displayName: String
    let brandColorHex: String = "#FF0000"
    let sfSymbolIcon: String = "hammer"

    init(sourceId: String = "mock", displayName: String = "Mock Tool") {
        self.sourceId = sourceId
        self.displayName = displayName
    }

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

    func testFirstRegistrationOrderIsPreserved() {
        let registry = AdapterRegistry()
        registry.register(MockAdapter(sourceId: "first"))
        registry.register(MockAdapter(sourceId: "second"))
        registry.register(MockAdapter(sourceId: "third"))

        XCTAssertEqual(registry.allAdapters().map(\.sourceId), ["first", "second", "third"])
    }

    func testReplacementPreservesRegistrationPosition() {
        let registry = AdapterRegistry()
        registry.register(MockAdapter(sourceId: "first"))
        registry.register(MockAdapter(sourceId: "second"))
        registry.register(MockAdapter(sourceId: "third"))
        registry.register(MockAdapter(sourceId: "second", displayName: "Replacement"))

        XCTAssertEqual(registry.allAdapters().map(\.sourceId), ["first", "second", "third"])
        XCTAssertEqual(registry.get(sourceId: "second")?.displayName, "Replacement")
        XCTAssertEqual(registry.allAdapters().count, 3)
    }

    func testConcurrentRegistrationAndReadsPreserveEveryAdapterOnce() {
        let registry = AdapterRegistry()
        let adapterCount = 100
        let reads = DispatchGroup()

        DispatchQueue.global().async(group: reads) {
            for _ in 0..<adapterCount {
                _ = registry.get(sourceId: "adapter-0")
                let adapters = registry.allAdapters()
                XCTAssertLessThanOrEqual(adapters.count, adapterCount)
                XCTAssertEqual(Set(adapters.map(\.sourceId)).count, adapters.count)
            }
        }

        DispatchQueue.concurrentPerform(iterations: adapterCount) { index in
            registry.register(MockAdapter(sourceId: "adapter-\(index)"))
        }
        reads.wait()

        let adapters = registry.allAdapters()
        XCTAssertEqual(adapters.count, adapterCount)
        XCTAssertEqual(Set(adapters.map(\.sourceId)).count, adapterCount)
        for index in 0..<adapterCount {
            XCTAssertNotNil(registry.get(sourceId: "adapter-\(index)"))
        }
    }
}
