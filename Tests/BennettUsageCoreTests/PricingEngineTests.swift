import XCTest
@testable import BennettUsageCore

final class PricingEngineTests: XCTestCase {
    func testCalculateCostForClaudeSonnet() {
        let engine = PricingEngine()
        // Claude 3.5 Sonnet: input $3/M, output $15/M, cache read $0.3/M, cache write $3.75/M
        let cost = engine.calculateCost(
            model: "claude-3-5-sonnet-20241022",
            input: 1_000_000,
            output: 100_000,
            cacheRead: 500_000,
            cacheWrite: 200_000
        )
        // 3.0 + 1.5 + 0.15 + 0.75 = 5.40
        XCTAssertEqual(cost, 5.40, accuracy: 0.001)
    }

    func testUnknownModelReturnsZero() {
        let engine = PricingEngine()
        let cost = engine.calculateCost(model: "totally-custom-private-model", input: 1000, output: 500)
        XCTAssertEqual(cost, 0.0)
    }

    func testCaseInsensitiveAndOtherModels() {
        let engine = PricingEngine()
        // GPT-4o-mini: input $0.15/M, output $0.60/M
        let costMini = engine.calculateCost(model: "GPT-4O-MINI-2024-07-18", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(costMini, 0.75, accuracy: 0.001)

        // GPT-4o: input $2.50/M, output $10.00/M
        let cost4o = engine.calculateCost(model: "gpt-4o-2024-08-06", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(cost4o, 12.50, accuracy: 0.001)
    }

    func testDeepSeekPricing() {
        let engine = PricingEngine()
        // DeepSeek Reasoner (R1): input $0.55/M, output $2.19/M, cache read $0.14/M, cache write $0.55/M
        let cost = engine.calculateCost(
            model: "deepseek-reasoner",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        // 0.55 + 2.19 + 0.14 + 0.55 = 3.43
        XCTAssertEqual(cost, 3.43, accuracy: 0.001)
    }

    func testUsdToCnyDefaultAndCustomRate() {
        let engine = PricingEngine()
        XCTAssertEqual(engine.usdToCnyRate, 7.20)
        engine.usdToCnyRate = 7.25
        XCTAssertEqual(engine.usdToCnyRate, 7.25)
    }

    func testDefaultRulesCoverage() {
        let rules = PricingEngine.defaultRules()
        XCTAssertFalse(rules.isEmpty)
        let patterns = rules.map(\.modelPattern)
        XCTAssertTrue(patterns.contains("claude-3-7-sonnet*"))
        XCTAssertTrue(patterns.contains("claude-3-5-sonnet*"))
        XCTAssertTrue(patterns.contains("claude-3-5-haiku*"))
        XCTAssertTrue(patterns.contains("claude-3-opus*"))
        XCTAssertTrue(patterns.contains("gpt-4o*"))
        XCTAssertTrue(patterns.contains("gpt-4o-mini*"))
        XCTAssertTrue(patterns.contains("o1*"))
        XCTAssertTrue(patterns.contains("o3-mini*"))
        XCTAssertTrue(patterns.contains("deepseek-chat*"))
        XCTAssertTrue(patterns.contains("deepseek-coder*"))
        XCTAssertTrue(patterns.contains("deepseek-reasoner*"))
    }
}
