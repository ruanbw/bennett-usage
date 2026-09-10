import Foundation
import Combine

/// Represents an application display language.
public struct AppLanguage: Hashable, Identifiable, Sendable, Codable, CustomStringConvertible {
    public let code: String
    public let displayName: String

    public var id: String { code }
    public var description: String { displayName }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let system = AppLanguage(code: "system", displayName: "System Default")
    public static let zh = AppLanguage(code: "zh", displayName: "简体中文")
    public static let en = AppLanguage(code: "en", displayName: "English")

    public static let standardLanguages: [AppLanguage] = [.system, .zh, .en]
}

/// Strongly typed keys for all localizable strings in Bennett Usage.
public enum LocalizedKey: String, CaseIterable, Sendable {
    // App & Common
    case appName
    case settings
    case done
    case cancel
    case general
    case about
    case language
    case version
    case systemDefault
    case aboutDescription

    // Dashboard Header & Range Picker
    case dashboardTitle
    case dashboardSubtitle
    case range
    case range24h
    case rangeToday
    case range7Days
    case range30Days
    case range1Year
    case years
    case rolling365Days
    case yearTitle

    // KPI Cards
    case periodTokens
    case todaysTokens
    case periodSpend
    case mostActiveAgent
    case totalTokensSuffix
    case spendSuffix
    case leadingVolume
    case none

    // Heatmap Section
    case tokenActivity
    case activeDaysCount
    case activityOnDay
    case activityDetail
    case less
    case more
    case noTokenUsage

    // Breakdown & Charts
    case toolShareBreakdown
    case noToolData
    case noActivityRecorded
    case hourlyTrendLast24h
    case hourlyTrendToday
    case dailyTrendLast7Days
    case dailyTrendLast30Days
    case monthlyTrendPastYear
    case monthlyTrendYear

    // Top Projects
    case topProjectsDrillDown
    case trackedProjectsCount
    case noProjectFoldersRecorded
    case tokensCount

    // MenuBar Popover
    case estimatedCost
    case toolBreakdownToday
    case syncNow
    case quit
    case openDashboardShortcut
    case statusItemAccessibility

    // Navigation & Redesign
    case navDashboard
    case navSettings
    case agentsConnected
    case rescanNow
    case syncedJustNow
    case syncedMinutesAgo
    case filterAllAgents
    case clearFocus
    case agentHealthSection
    case pricingSection
    case storageSection
    case exchangeRateLabel
    case preferredCurrencyLabel
    case revealInFinder
    case rebuildRollups
    case clearAllRecords
    case clearRecordsConfirmTitle
    case clearRecordsConfirmMessage
    case autoRefreshLabel
    case autoRefreshOff
    case autoRefreshSeconds
    case storageStatus
    case generalSettings
    case usdOption
    case cnyOption
}

public typealias LocalizationKey = LocalizedKey

/// Global localization manager supporting instant reactive language switching,
/// system fallback, persistence, and dynamic registration of new languages.
public final class LocalizationManager: ObservableObject, @unchecked Sendable {
    public static let shared = LocalizationManager()

    public static let userDefaultsKey = "bennett_app_language_code"

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    @Published public private(set) var selectedLanguage: AppLanguage = .system
    @Published public private(set) var availableLanguages: [AppLanguage] = AppLanguage.standardLanguages

    private var translations: [String: [LocalizedKey: String]] = [:]

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadDefaultTranslations()
        restorePersistedLanguage()
    }

    /// Resolves the actual language to display (handles `.system` resolution).
    public var effectiveLanguage: AppLanguage {
        lock.lock()
        defer { lock.unlock() }

        if selectedLanguage.code != AppLanguage.system.code {
            return selectedLanguage
        }

        // Detect system preferred language
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.lowercased().starts(with: "zh") {
            return .zh
        }
        return .en
    }

    /// Change current language preference and persist.
    public func setLanguage(_ language: AppLanguage) {
        lock.lock()
        selectedLanguage = language
        if !availableLanguages.contains(where: { $0.code == language.code }) {
            availableLanguages.append(language)
        }
        userDefaults.set(language.code, forKey: Self.userDefaultsKey)
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Register a new language pack dynamically for extensibility.
    public func registerLanguage(_ language: AppLanguage, translations newTranslations: [LocalizedKey: String]) {
        lock.lock()
        if !availableLanguages.contains(where: { $0.code == language.code }) {
            availableLanguages.append(language)
        }
        var currentDict = translations[language.code] ?? [:]
        for (k, v) in newTranslations {
            currentDict[k] = v
        }
        translations[language.code] = currentDict
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Lookup localized string for key.
    public func localized(_ key: LocalizedKey, language: AppLanguage? = nil, arguments: CVarArg...) -> String {
        let lang = language ?? effectiveLanguage
        let formatString = stringFor(key: key, languageCode: lang.code)
        if arguments.isEmpty {
            return formatString
        }
        return String(format: formatString, arguments: arguments)
    }

    private func stringFor(key: LocalizedKey, languageCode: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        // 1. Check specified language dictionary
        if let text = translations[languageCode]?[key] {
            return text
        }
        // 2. Fallback to English
        if let fallback = translations[AppLanguage.en.code]?[key] {
            return fallback
        }
        // 3. Last resort: raw key
        return key.rawValue
    }

    private func restorePersistedLanguage() {
        if let savedCode = userDefaults.string(forKey: Self.userDefaultsKey) {
            if savedCode == AppLanguage.zh.code {
                selectedLanguage = .zh
            } else if savedCode == AppLanguage.en.code {
                selectedLanguage = .en
            } else if savedCode == AppLanguage.system.code {
                selectedLanguage = .system
            } else if let found = availableLanguages.first(where: { $0.code == savedCode }) {
                selectedLanguage = found
            } else {
                selectedLanguage = .system
            }
        }
    }

    private func loadDefaultTranslations() {
        translations[AppLanguage.en.code] = englishDictionary
        translations[AppLanguage.zh.code] = chineseDictionary
    }
}

// MARK: - Built-in Translation Dictionaries

private let englishDictionary: [LocalizedKey: String] = [
    // App & Common
    .appName: "Bennett Usage",
    .settings: "Settings",
    .done: "Done",
    .cancel: "Cancel",
    .general: "General",
    .about: "About",
    .language: "Language",
    .version: "Version",
    .systemDefault: "System Default",
    .aboutDescription: "Unified local AI agent token usage, activity, and cost tracking for macOS.",

    // Dashboard Header & Range Picker
    .dashboardTitle: "Bennett Usage Analytics",
    .dashboardSubtitle: "Unified local AI agent token usage, activity, and cost tracking",
    .range: "Range",
    .range24h: "24h",
    .rangeToday: "Today",
    .range7Days: "7 Days",
    .range30Days: "30 Days",
    .range1Year: "1 Year",
    .years: "Years",
    .rolling365Days: "Rolling 365 Days",
    .yearTitle: "Year %@",

    // KPI Cards
    .periodTokens: "Period Tokens",
    .todaysTokens: "Today's Tokens",
    .periodSpend: "Period Spend ($ / ¥)",
    .mostActiveAgent: "Most Active Agent",
    .totalTokensSuffix: "%@ Total",
    .spendSuffix: "%@ Spend",
    .leadingVolume: "Leading Volume",
    .none: "None",

    // Heatmap Section
    .tokenActivity: "Token Activity (%@)",
    .activeDaysCount: "%d active days",
    .activityOnDay: "Activity on %@",
    .activityDetail: "Total Tokens: %@ · Cost: $%@",
    .less: "Less",
    .more: "More",
    .noTokenUsage: "%@: No token usage",

    // Breakdown & Charts
    .toolShareBreakdown: "Tool Share Breakdown (%@)",
    .noToolData: "No tool data for %@",
    .noActivityRecorded: "No activity recorded for %@",
    .hourlyTrendLast24h: "Hourly Token Trend (Last 24h)",
    .hourlyTrendToday: "Hourly Token Trend (Today)",
    .dailyTrendLast7Days: "Daily Token Trend (Last 7 Days)",
    .dailyTrendLast30Days: "Daily Token Trend (Last 30 Days)",
    .monthlyTrendPastYear: "Monthly Token Trend (Past Year)",
    .monthlyTrendYear: "Monthly Token Trend (%@)",

    // Top Projects
    .topProjectsDrillDown: "Top Projects Drill-Down",
    .trackedProjectsCount: "%d tracked",
    .noProjectFoldersRecorded: "No project folders recorded yet",
    .tokensCount: "%@ tokens",

    // MenuBar Popover
    .estimatedCost: "Estimated Cost",
    .toolBreakdownToday: "Tool Breakdown (Today)",
    .syncNow: "Sync Now",
    .quit: "Quit",
    .openDashboardShortcut: "Open Dashboard (⌘D)",
    .statusItemAccessibility: "Bennett Usage",

    // Navigation & Redesign
    .navDashboard: "Dashboard",
    .navSettings: "Settings",
    .agentsConnected: "%d Agents Connected",
    .rescanNow: "Sync Now",
    .syncedJustNow: "Synced just now",
    .syncedMinutesAgo: "Synced %d mins ago",
    .filterAllAgents: "All Agents",
    .clearFocus: "Clear Focus",
    .agentHealthSection: "Agent Data Sources & Health Diagnostics",
    .pricingSection: "Pricing & Currency",
    .storageSection: "Storage & Maintenance",
    .exchangeRateLabel: "USD ⇄ CNY Exchange Rate",
    .preferredCurrencyLabel: "Preferred Currency",
    .revealInFinder: "Reveal in Finder",
    .rebuildRollups: "Rebuild Aggregates",
    .clearAllRecords: "Clear All Records...",
    .clearRecordsConfirmTitle: "Clear All Local Usage Records?",
    .clearRecordsConfirmMessage: "This will reset the local database. If raw agent logs remain, they will be rescanned on next sync.",
    .autoRefreshLabel: "Auto Refresh Interval",
    .autoRefreshOff: "Manual",
    .autoRefreshSeconds: "%d seconds",
    .storageStatus: "%d records · %@ on disk",
    .generalSettings: "General Settings",
    .usdOption: "USD ($)",
    .cnyOption: "CNY (¥)"
]

private let chineseDictionary: [LocalizedKey: String] = [
    // App & Common
    .appName: "Bennett Usage",
    .settings: "设置",
    .done: "完成",
    .cancel: "取消",
    .general: "通用",
    .about: "关于",
    .language: "语言",
    .version: "版本",
    .systemDefault: "跟随系统",
    .aboutDescription: "专为 macOS 设计的本地 AI Agent Token 消耗、活跃度与费用统一追踪面板。",

    // Dashboard Header & Range Picker
    .dashboardTitle: "Bennett Usage 数据看板",
    .dashboardSubtitle: "统一监控本地 AI Agent 的 Token 消耗、活跃度与费用支出",
    .range: "时间范围",
    .range24h: "24小时",
    .rangeToday: "今日",
    .range7Days: "7天",
    .range30Days: "30天",
    .range1Year: "1年",
    .years: "年份",
    .rolling365Days: "滚动 365 天",
    .yearTitle: "%@ 年",

    // KPI Cards
    .periodTokens: "选定时段 Token",
    .todaysTokens: "今日 Token",
    .periodSpend: "时段支出 ($ / ¥)",
    .mostActiveAgent: "最活跃 Agent",
    .totalTokensSuffix: "%@ 总计",
    .spendSuffix: "%@ 支出",
    .leadingVolume: "消耗占比最高",
    .none: "无",

    // Heatmap Section
    .tokenActivity: "Token 活跃度 (%@)",
    .activeDaysCount: "%d 个活跃天数",
    .activityOnDay: "%@ 的活跃数据",
    .activityDetail: "总 Token: %@ · 费用: $%@",
    .less: "少",
    .more: "多",
    .noTokenUsage: "%@: 无 Token 消耗",

    // Breakdown & Charts
    .toolShareBreakdown: "各工具消耗占比 (%@)",
    .noToolData: "%@ 暂无工具数据",
    .noActivityRecorded: "%@ 暂无活动记录",
    .hourlyTrendLast24h: "小时级 Token 趋势 (最近 24 小时)",
    .hourlyTrendToday: "小时级 Token 趋势 (今日)",
    .dailyTrendLast7Days: "日级 Token 趋势 (最近 7 天)",
    .dailyTrendLast30Days: "日级 Token 趋势 (最近 30 天)",
    .monthlyTrendPastYear: "月度 Token 趋势 (过去一年)",
    .monthlyTrendYear: "月度 Token 趋势 (%@)",

    // Top Projects
    .topProjectsDrillDown: "项目目录深度分析",
    .trackedProjectsCount: "已记录 %d 个",
    .noProjectFoldersRecorded: "暂无已记录的项目目录",
    .tokensCount: "%@ tokens",

    // MenuBar Popover
    .estimatedCost: "预估费用",
    .toolBreakdownToday: "工具分布 (今日)",
    .syncNow: "立即同步",
    .quit: "退出",
    .openDashboardShortcut: "打开数据看板 (⌘D)",
    .statusItemAccessibility: "Bennett Usage",

    // Navigation & Redesign
    .navDashboard: "用量看板",
    .navSettings: "系统设置",
    .agentsConnected: "%d 个 Agent 正常",
    .rescanNow: "立即同步",
    .syncedJustNow: "刚刚同步",
    .syncedMinutesAgo: "%d 分钟前同步",
    .filterAllAgents: "全部 Agent",
    .clearFocus: "清除聚焦",
    .agentHealthSection: "Agent 数据源接入与状态诊断",
    .pricingSection: "计价与货币",
    .storageSection: "数据存储与维护",
    .exchangeRateLabel: "USD ⇄ CNY 参考汇率",
    .preferredCurrencyLabel: "主显示币种",
    .revealInFinder: "在访达中显示",
    .rebuildRollups: "重新聚合数据",
    .clearAllRecords: "清空所有记录...",
    .clearRecordsConfirmTitle: "确定清空所有本地用量记录？",
    .clearRecordsConfirmMessage: "此操作将重置本地记录数据库。若 Agent 原始日志仍然存在，下次同步将重新扫描收录。",
    .autoRefreshLabel: "自动刷新频率",
    .autoRefreshOff: "手动刷新",
    .autoRefreshSeconds: "%d 秒",
    .storageStatus: "%d 条用量记录 · 占用空间约 %@",
    .generalSettings: "通用设置",
    .usdOption: "美元 USD ($)",
    .cnyOption: "人民币 CNY (¥)"
]
