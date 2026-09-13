import XCTest
@testable import BennettUsageCore

final class ScaffoldTests: XCTestCase {
    func testCoreVersionString() {
        XCTAssertEqual(BennettUsageCore.version, "1.1.0")
    }
}
