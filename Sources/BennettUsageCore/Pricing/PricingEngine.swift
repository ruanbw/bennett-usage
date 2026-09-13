import Foundation

public enum PreferredCurrency: String, Sendable, CaseIterable, Codable {
    case usd
    case cny
}

public final class PricingEngine: @unchecked Sendable {
    public static let shared = PricingEngine()
    public static let rateUserDefaultsKey = "bennett_usd_to_cny_rate"
    public static let currencyUserDefaultsKey = "bennett_preferred_currency"

    /// A pricing pattern precompiled once at init. Avoids re-deriving the
    /// prefix (and allocating a `String`) for every record during sync.
    private struct CompiledRule {
        /// Pattern with any trailing `*` stripped; compared against the
        /// lowercased model name.
        let prefix: String
        /// `true` when the pattern ended in `*` (prefix match), otherwise the
        /// pattern must equal the model name exactly.
        let isPrefixMatch: Bool
    }

    /// Longest-pattern-first; built once so `calculateCost` does not sort per record.
    private var sortedRules: [ModelPricing] = []
    /// `sortedRules` with patterns precompiled, in the same order.
    private var compiledRules: [CompiledRule] = []
    /// Memoizes `model -> sortedRules index` (or `-1` for no match). Model
    /// names repeat heavily within a sync, so this removes the lowercasing and
    /// pattern scan from the steady-state hot path. Guarded by `lock`.
    private var resolutionCache: [String: Int] = [:]
    private static let resolutionCacheLimit = 512
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
        self.sortedRules = Self.defaultRules().sorted { $0.modelPattern.count > $1.modelPattern.count }
        self.compiledRules = sortedRules.map { rule in
            if rule.modelPattern.hasSuffix("*") {
                return CompiledRule(prefix: String(rule.modelPattern.dropLast()), isPrefixMatch: true)
            }
            return CompiledRule(prefix: rule.modelPattern, isPrefixMatch: false)
        }
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

    /// Single-currency display honoring the preferred currency. Previously
    /// this returned a dual "$x (¥y)" string regardless of the setting, so a
    /// USD preference still showed RMB everywhere.
    public func spendString(_ costUSD: Double) -> String {
        // Single lock acquisition for both values; all formatting happens
        // outside the lock.
        let (rate, currency) = spendSnapshot()
        switch currency {
        case .usd:
            return "$" + String(format: "%.2f", costUSD)
        case .cny:
            return "¥" + String(format: "%.2f", costUSD * rate)
        }
    }

    /// Reads the exchange rate and preferred currency under a single lock
    /// acquisition. Private helper; callers must not hold `lock` while doing
    /// any formatting work.
    private func spendSnapshot() -> (rate: Double, currency: PreferredCurrency) {
        lock.lock()
        defer { lock.unlock() }
        return (_usdToCnyRate, _preferredCurrency)
    }

    public static func defaultRules() -> [ModelPricing] {
        return [
            // Claude Models
            ModelPricing(modelPattern: "claude-opus-4*", inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
            ModelPricing(modelPattern: "claude-sonnet-4*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-haiku-4*", inputPerMillion: 0.80, outputPerMillion: 4.00, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
            ModelPricing(modelPattern: "claude-3-7-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-sonnet*", inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
            ModelPricing(modelPattern: "claude-3-5-haiku*", inputPerMillion: 0.80, outputPerMillion: 4.00, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
            ModelPricing(modelPattern: "claude-3-opus*", inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
            // OpenAI Models
            ModelPricing(modelPattern: "gpt-5*", inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25),
            ModelPricing(modelPattern: "gpt-4.1*", inputPerMillion: 2.00, outputPerMillion: 8.00, cacheReadPerMillion: 0.50, cacheWritePerMillion: 2.00),
            ModelPricing(modelPattern: "o4-mini*", inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.275, cacheWritePerMillion: 1.10),
            ModelPricing(modelPattern: "gpt-4o*", inputPerMillion: 2.50, outputPerMillion: 10.00, cacheReadPerMillion: 1.25, cacheWritePerMillion: 2.50),
            ModelPricing(modelPattern: "gpt-4o-mini*", inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.15),
            ModelPricing(modelPattern: "o1*", inputPerMillion: 15.0, outputPerMillion: 60.0, cacheReadPerMillion: 7.50, cacheWritePerMillion: 15.0),
            ModelPricing(modelPattern: "o3-mini*", inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, cacheWritePerMillion: 1.10),
            // DeepSeek Models
            ModelPricing(modelPattern: "deepseek-chat*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-coder*", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14),
            ModelPricing(modelPattern: "deepseek-reasoner*", inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14, cacheWritePerMillion: 0.55),
            ModelPricing(modelPattern: "deepseek-r1*", inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14, cacheWritePerMillion: 0.55),
            ModelPricing(modelPattern: "deepseek-v3*", inputPerMillion: 0.27, outputPerMillion: 1.10, cacheReadPerMillion: 0.027, cacheWritePerMillion: 0.27),
            // Google Gemini Models
            ModelPricing(modelPattern: "gemini-2.5-pro*", inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25),
            ModelPricing(modelPattern: "gemini-2.5-flash*", inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.03, cacheWritePerMillion: 0.30),
            ModelPricing(modelPattern: "gemini-3*", inputPerMillion: 2.00, outputPerMillion: 12.00, cacheReadPerMillion: 0.20, cacheWritePerMillion: 2.00),
            ModelPricing(modelPattern: "gemini-*", inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25),
            ModelPricing(modelPattern: "gemini*", inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25),
            // Alibaba Qwen Models
            ModelPricing(modelPattern: "qwen3*", inputPerMillion: 0.35, outputPerMillion: 1.40, cacheReadPerMillion: 0.07, cacheWritePerMillion: 0.35),
            ModelPricing(modelPattern: "qwen-*", inputPerMillion: 0.35, outputPerMillion: 1.40, cacheReadPerMillion: 0.07, cacheWritePerMillion: 0.35),
            ModelPricing(modelPattern: "qwen*", inputPerMillion: 0.35, outputPerMillion: 1.40, cacheReadPerMillion: 0.07, cacheWritePerMillion: 0.35),
            // Moonshot Kimi Models
            ModelPricing(modelPattern: "kimi-k2*", inputPerMillion: 0.60, outputPerMillion: 2.50, cacheReadPerMillion: 0.06, cacheWritePerMillion: 0.60),
            ModelPricing(modelPattern: "kimi*", inputPerMillion: 0.60, outputPerMillion: 2.50, cacheReadPerMillion: 0.06, cacheWritePerMillion: 0.60),
            // Zhipu GLM Models
            ModelPricing(modelPattern: "glm-*", inputPerMillion: 0.50, outputPerMillion: 1.50, cacheReadPerMillion: 0.05, cacheWritePerMillion: 0.50)
        ]
    }

    public func calculateCost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> Double {
        let index = resolvedRuleIndex(for: model)
        guard index >= 0 else { return 0.0 }
        let rule = sortedRules[index]

        let inputCost = (Double(input) / 1_000_000.0) * rule.inputPerMillion
        let outputCost = (Double(output) / 1_000_000.0) * rule.outputPerMillion
        let cacheReadCost = (Double(cacheRead) / 1_000_000.0) * rule.cacheReadPerMillion
        let cacheWriteCost = (Double(cacheWrite) / 1_000_000.0) * rule.cacheWritePerMillion

        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }

    private func matchCompiledRule(for candidate: String) -> Int {
        for (index, compiled) in compiledRules.enumerated() {
            let hit = compiled.isPrefixMatch
                ? candidate.hasPrefix(compiled.prefix)
                : candidate == compiled.prefix
            if hit {
                return index
            }
        }
        return -1
    }

    /// Index into `sortedRules` for `model`, or `-1` when nothing matches.
    /// Model names repeat heavily during a sync, so the resolved index is
    /// memoized; the underlying rules are immutable after `init`.
    private func resolvedRuleIndex(for model: String) -> Int {
        lock.lock()
        if let cached = resolutionCache[model] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let lower = model.lowercased()
        var resolved = matchCompiledRule(for: lower)

        if resolved == -1 {
            var candidate = lower
            if candidate.contains("/") {
                candidate = String(candidate.split(separator: "/").last ?? "")
                resolved = matchCompiledRule(for: candidate)
            }
            if resolved == -1 && candidate.contains(":") {
                candidate = String(candidate.split(separator: ":").last ?? "")
                resolved = matchCompiledRule(for: candidate)
            }
        }

        lock.lock()
        if resolutionCache.count < Self.resolutionCacheLimit {
            resolutionCache[model] = resolved
        }
        lock.unlock()
        return resolved
    }
}
