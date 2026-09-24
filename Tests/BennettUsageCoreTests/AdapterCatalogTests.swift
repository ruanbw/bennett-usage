import XCTest
@testable import BennettUsageCore

final class AdapterCatalogTests: XCTestCase {
    private let expectedSourceIds = [
        "omp", "pi", "claude", "codex", "continue", "gemini", "antigravity", "opencode",
        "roo", "cline", "qwen", "copilot", "cursor", "trae", "dsh", "goose", "crush", "kimi"
    ]

    func testDefaultsPreserveBuiltInAdapterOrderAndCollection() {
        let sourceIds = AdapterCatalog.defaults.map(\.sourceId)

        XCTAssertEqual(sourceIds, expectedSourceIds)
        XCTAssertEqual(Set(sourceIds), Set(expectedSourceIds))
        XCTAssertEqual(sourceIds.count, 18)
    }

    func testDefaultsReturnsIndependentAdapters() {
        var first = AdapterCatalog.defaults
        let second = AdapterCatalog.defaults

        XCTAssertEqual(first.map(\.sourceId), second.map(\.sourceId))
        first[0] = MockAdapter()

        XCTAssertEqual(second.map(\.sourceId), expectedSourceIds)
        XCTAssertTrue(second[0] is OmpAdapter)
    }
}
