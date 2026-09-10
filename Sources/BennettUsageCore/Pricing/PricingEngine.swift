import Foundation

public enum PreferredCurrency: String, Sendable, CaseIterable, Codable {
    case usd
    case cny
}

public final class PricingEngine: @unchecked Sendable {
    public static let shared = PricingEngine()
    public static let rateUserDefaultsKey = "bennett_usd_to_cny_rate"
    public static let currencyUserDefaultsKey = "bennett_preferred_currency"

    private var rules: [ModelPricing] = []
    private let lock = NSLock()
    private var _usdToCnyRate: Double = 7.30
    private var _preferredCurrency: PreferredCurrency = .usd

    public var usdToCnyRate: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _usdToCnyRate
        }
        set {
            setExchangeRate(newValue)
        }
    }

    public var preferredCurrency: PreferredCurrency {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _preferredCurrency
        }
        set {
            setPreferredCurrency(newValue)
        }
    }

    public init() {
        self.rules = Self.defaultRules()
        let savedRate = UserDefaults.standard.double(forKey: Self.rateUserDefaultsKey)
        if savedRate > 0 {
            self._usdToCnyRate = savedRate
        } else {
            self._usdToCnyRate = 7.30
        }

        if let savedCurrencyRaw = UserDefaults.standard.string(forKey: Self.currencyUserDefaultsKey),
           let savedCurrency = PreferredCurrency(rawValue: savedCurrencyRaw) {
            self._preferredCurrency = savedCurrency
        } else {
            self._preferredCurrency = .usd
        }
    }

    public func setExchangeRate(_ rate: Double) {
        lock.lock()
        _usdToCnyRate = rate
        lock.unlock()
        UserDefaults.standard.set(rate, forKey: Self.rateUserDefaultsKey)
    }

    public func setPreferredCurrency(_ currency: PreferredCurrency) {
        lock.lock()
        _preferredCurrency = currency
        lock.unlock()
        UserDefaults.standard.set(currency.rawValue, forKey: Self.currencyUserDefaultsKey)
    }

    public func spendString(_ costUSD: Double) -> String {
        let rate = usdToCnyRate
        let currency = preferredCurrency
        switch currency {
        case .usd:
            return "$\(String(format: "%.2f", costUSD)) (¥\(String(format: "%.2f", costUSD * rate)))"
        case .cny:
            return "¥\(String(format: "%.2f", costUSD * rate)) ($\(String(format: "%.2f", costUSD)))"
        }
    }

    public static func defaultRules() -> [ModelPricing] {
        return [
            // Claude Models
            ModelPricing(modelPattern: "claude-3-7-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-haiku*", inputPerMillion: 0.80, outputPerMillion: 4.00, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
            ModelPricing(modelPattern: "claude-3-opus*", inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
            // OpenAI Models
            ModelPricing(modelPattern: "gpt-4o*", inputPerMillion: 2.50, outputPerMillion: 10.00, cacheReadPerMillion: 1.25, cacheWritePerMillion: 2.50),
            ModelPricing(modelPattern: "gpt-4o-mini*", inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.15),
            ModelPricing(modelPattern: "o1*", inputPerMillion: 15.0, outputPerMillion: 60.0, cacheReadPerMillion: 7.50, cacheWritePerMillion: 15.0),
            ModelPricing(modelPattern: "o3-mini*", inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, cacheWritePerMillion: 1.10),
            // DeepSeek Models
            ModelPricing(modelPattern: "deepseek-chat*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-coder*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-reasoner*", inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14, cacheWritePerMillion: 0.55)
        ]
    }

    public func calculateCost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> Double {
        lock.lock(); defer { lock.unlock() }
        let lower = model.lowercased()
        guard let rule = rules
            .filter({ matches(pattern: $0.modelPattern, string: lower) })
            .sorted(by: { $0.modelPattern.count > $1.modelPattern.count })
            .first
        else {
            return 0.0
        }

        let inputCost = (Double(input) / 1_000_000.0) * rule.inputPerMillion
        let outputCost = (Double(output) / 1_000_000.0) * rule.outputPerMillion
        let cacheReadCost = (Double(cacheRead) / 1_000_000.0) * rule.cacheReadPerMillion
        let cacheWriteCost = (Double(cacheWrite) / 1_000_000.0) * rule.cacheWritePerMillion

        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }

    private func matches(pattern: String, string: String) -> Bool {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return string.hasPrefix(prefix)
        }
        return pattern == string
    }
}
