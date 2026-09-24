import XCTest
@testable import BennettUsageCore

final class ScaffoldTests: XCTestCase {
    /// The compiled-in fallback must stay in step with the released version —
    /// it is what the update checker compares against when the executable runs
    /// outside a packaged bundle (tests, `swift run`).
    func testCoreVersionString() {
        XCTAssertEqual(BennettUsageCore.version, "1.4.1")
        XCTAssertEqual(AppVersion(BennettUsageCore.version)?.description, BennettUsageCore.version)
    }
}
