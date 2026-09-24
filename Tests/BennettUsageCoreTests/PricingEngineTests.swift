import Combine
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
        let originalRate = UserDefaults.standard.double(forKey: "bennett_usd_to_cny_rate")
        defer {
            if originalRate > 0 {
                UserDefaults.standard.set(originalRate, forKey: "bennett_usd_to_cny_rate")
            } else {
                UserDefaults.standard.removeObject(forKey: "bennett_usd_to_cny_rate")
            }
        }
        UserDefaults.standard.removeObject(forKey: "bennett_usd_to_cny_rate")
        let engine = PricingEngine()
        XCTAssertEqual(engine.usdToCnyRate, 7.30, accuracy: 0.001)
        engine.usdToCnyRate = 7.25
        XCTAssertEqual(engine.usdToCnyRate, 7.25, accuracy: 0.001)
    }

    func testDynamicExchangeRateAndPreferredCurrency() {
        let originalRate = UserDefaults.standard.double(forKey: "bennett_usd_to_cny_rate")
        let originalCurrency = UserDefaults.standard.string(forKey: "bennett_preferred_currency")
        defer {
            if originalRate > 0 {
                UserDefaults.standard.set(originalRate, forKey: "bennett_usd_to_cny_rate")
            } else {
                UserDefaults.standard.removeObject(forKey: "bennett_usd_to_cny_rate")
            }
            if let originalCurrency = originalCurrency {
                UserDefaults.standard.set(originalCurrency, forKey: "bennett_preferred_currency")
            } else {
                UserDefaults.standard.removeObject(forKey: "bennett_preferred_currency")
            }
        }

        UserDefaults.standard.removeObject(forKey: "bennett_usd_to_cny_rate")
        UserDefaults.standard.removeObject(forKey: "bennett_preferred_currency")

        let freshEngine = PricingEngine()
        XCTAssertEqual(freshEngine.usdToCnyRate, 7.30, accuracy: 0.001)
        XCTAssertEqual(freshEngine.preferredCurrency, .usd)

        freshEngine.setExchangeRate(7.25)
        XCTAssertEqual(freshEngine.usdToCnyRate, 7.25, accuracy: 0.001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "bennett_usd_to_cny_rate"), 7.25, accuracy: 0.001)

        freshEngine.setPreferredCurrency(.cny)
        XCTAssertEqual(freshEngine.preferredCurrency, .cny)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "bennett_preferred_currency"), "cny")

        // Test spendString: single-currency honoring the preference.
        // With .cny: "¥\(costUSD * rate)"
        XCTAssertEqual(freshEngine.spendString(10.0), "¥72.50")

        // With .usd: "$\(costUSD)"
        freshEngine.setPreferredCurrency(.usd)
        XCTAssertEqual(freshEngine.spendString(10.0), "$10.00")
    }

    @MainActor
    func testPricingChangesPublishObjectWillChange() {
        let originalRate = UserDefaults.standard.double(forKey: PricingEngine.rateUserDefaultsKey)
        let originalCurrency = UserDefaults.standard.string(forKey: PricingEngine.currencyUserDefaultsKey)
        defer {
            if originalRate > 0 {
                UserDefaults.standard.set(originalRate, forKey: PricingEngine.rateUserDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PricingEngine.rateUserDefaultsKey)
            }
            if let originalCurrency {
                UserDefaults.standard.set(originalCurrency, forKey: PricingEngine.currencyUserDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PricingEngine.currencyUserDefaultsKey)
            }
        }

        UserDefaults.standard.set(7.30, forKey: PricingEngine.rateUserDefaultsKey)
        UserDefaults.standard.set(PreferredCurrency.usd.rawValue, forKey: PricingEngine.currencyUserDefaultsKey)
        let engine = PricingEngine()
        var changeCount = 0
        let observation = engine.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { observation.cancel() }

        engine.setExchangeRate(7.25)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(engine.spendString(10.0), "$10.00")

        engine.setPreferredCurrency(.cny)
        XCTAssertEqual(changeCount, 2)
        XCTAssertEqual(engine.spendString(10.0), "¥72.50")

        engine.setPreferredCurrency(.usd)
        XCTAssertEqual(changeCount, 3)
        XCTAssertEqual(engine.spendString(10.0), "$10.00")
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
        XCTAssertTrue(patterns.contains("deepseek-r1*"))
        XCTAssertTrue(patterns.contains("gemini*"))
        XCTAssertTrue(patterns.contains("qwen*"))
    }

    func testProviderPrefixMatching() {
        let engine = PricingEngine()
        // Provider prefix with slash
        let costSlash = engine.calculateCost(
            model: "anthropic/claude-3-5-sonnet",
            input: 1_000_000,
            output: 100_000,
            cacheRead: 500_000,
            cacheWrite: 200_000
        )
        XCTAssertGreaterThan(costSlash, 0.0)
        XCTAssertEqual(costSlash, 5.40, accuracy: 0.001)

        // Provider prefix with colon
        let costColon = engine.calculateCost(
            model: "anthropic:claude-3-5-sonnet",
            input: 1_000_000,
            output: 100_000,
            cacheRead: 500_000,
            cacheWrite: 200_000
        )
        XCTAssertGreaterThan(costColon, 0.0)
        XCTAssertEqual(costColon, 5.40, accuracy: 0.001)
    }

    func testDeepSeekR1AndQwenPricing() {
        let engine = PricingEngine()
        // DeepSeek R1: input $0.55/M, output $2.19/M, cache read $0.14/M, cache write $0.55/M
        let costR1 = engine.calculateCost(
            model: "deepseek-r1",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        XCTAssertGreaterThan(costR1, 0.0)
        XCTAssertEqual(costR1, 3.43, accuracy: 0.001)

        // Qwen base model: input $0.35/M, output $1.40/M, cache read $0.07/M, cache write $0.35/M
        let costQwen = engine.calculateCost(
            model: "qwen",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        XCTAssertGreaterThan(costQwen, 0.0)
        XCTAssertEqual(costQwen, 2.17, accuracy: 0.001)

        // Qwen derivative
        let costQwenCoder = engine.calculateCost(
            model: "qwen2.5-coder-32b",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        XCTAssertGreaterThan(costQwenCoder, 0.0)
        XCTAssertEqual(costQwenCoder, 2.17, accuracy: 0.001)
    }
}
