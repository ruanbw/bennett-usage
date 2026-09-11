import XCTest
@testable import BennettUsageCore

final class TokenFormatterTests: XCTestCase {
    func testFormatCompactSubThousand() {
        XCTAssertEqual(TokenFormatter.formatCompact(0), "0")
        XCTAssertEqual(TokenFormatter.formatCompact(42), "42")
        XCTAssertEqual(TokenFormatter.formatCompact(999), "999")
    }

    func testFormatCompactThousands() {
        XCTAssertEqual(TokenFormatter.formatCompact(1_000), "1k")
        XCTAssertEqual(TokenFormatter.formatCompact(1_200), "1.2k")
        XCTAssertEqual(TokenFormatter.formatCompact(1_250), "1.3k")
        XCTAssertEqual(TokenFormatter.formatCompact(15_000), "15k")
        XCTAssertEqual(TokenFormatter.formatCompact(15_400), "15.4k")
        XCTAssertEqual(TokenFormatter.formatCompact(150_000), "150k")
        XCTAssertEqual(TokenFormatter.formatCompact(150_600), "150.6k")
    }

    func testFormatCompactMillions() {
        XCTAssertEqual(TokenFormatter.formatCompact(1_000_000), "1M")
        XCTAssertEqual(TokenFormatter.formatCompact(1_250_000), "1.25M")
        XCTAssertEqual(TokenFormatter.formatCompact(1_200_000), "1.2M")
        XCTAssertEqual(TokenFormatter.formatCompact(14_250_000), "14.3M")
        XCTAssertEqual(TokenFormatter.formatCompact(120_000_000), "120M")
        XCTAssertEqual(TokenFormatter.formatCompact(120_500_000), "120.5M")
    }

    func testFormatCompactBillions() {
        XCTAssertEqual(TokenFormatter.formatCompact(1_000_000_000), "1B")
        XCTAssertEqual(TokenFormatter.formatCompact(1_450_000_000), "1.45B")
        XCTAssertEqual(TokenFormatter.formatCompact(12_000_000_000), "12B")
    }

    func testFormatCompactUnitBoundaryEscalation() {
        // Values that round to 1000 of a unit must escalate to the next unit.
        XCTAssertEqual(TokenFormatter.formatCompact(999_949), "999.9k")
        XCTAssertEqual(TokenFormatter.formatCompact(999_950), "1M")
        XCTAssertEqual(TokenFormatter.formatCompact(999_999), "1M")
        XCTAssertEqual(TokenFormatter.formatCompact(-999_999), "-1M")
        XCTAssertEqual(TokenFormatter.formatCompact(999_949_999), "999.9M")
        XCTAssertEqual(TokenFormatter.formatCompact(999_950_000), "1B")
        XCTAssertEqual(TokenFormatter.formatCompact(999_999_999), "1B")
    }

    func testFormatFull() {
        XCTAssertEqual(TokenFormatter.formatFull(0), "0")
        XCTAssertEqual(TokenFormatter.formatFull(999), "999")
        XCTAssertEqual(TokenFormatter.formatFull(1_000), "1,000")
        XCTAssertEqual(TokenFormatter.formatFull(14_250_000), "14,250,000")
    }

    func testFormatWithTooltip() {
        let result = TokenFormatter.formatWithTooltip(14_250_000)
        XCTAssertEqual(result.compact, "14.3M")
        XCTAssertEqual(result.tooltip, "14,250,000 tokens")
    }

    func testFormatStatusTitle() {
        XCTAssertEqual(TokenFormatter.formatStatusTitle(0), "")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(-100), "")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(950), " 950")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(15_400), " 15.4k")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(306_178_000), " 306.2M")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(306_434_461), " 306.4M")
        XCTAssertEqual(TokenFormatter.formatStatusTitle(1_200_000_000), " 1.2B")
    }
}
