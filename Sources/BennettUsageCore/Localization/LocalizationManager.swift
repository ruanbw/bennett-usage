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
    case rangeTokens

    // Heatmap Section
    case annualPanorama
    case annualTotalTokens
    case annualSpend
    case annualActiveDays
    case annualPrimaryAgent
    case viewAnnualDashboard
    case viewingAnnualDashboard
    case exitAnnualDashboard
    case heatmapView
    case calendarView
    case monthlyTrend
    case tokenActivity
    case tokenUnit
    case activeDaysCount
    case activityOnDay
    case activityDetail
    case less
    case more
    case noTokenUsage

    // Breakdown & Charts
    case toolDistribution
    case modelDistribution
    case toolShareBreakdown
    case modelUsageBreakdown
    case noToolData
    case noModelData
    case noActivityRecorded
    case chartType
    case chartTypeBar
    case chartTypeLine
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
    case showMoreProjects
    case showLess
    // MenuBar Popover
    case estimatedCost
    case toolBreakdownToday
    case noToolsActiveToday
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
    case allAgentsUsage
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
    case rebuildRollupsDescription
    case clearRecordsDescription
    case maintenanceSucceeded
    case maintenanceFailed
    case autoRefreshLabel
    case autoRefreshOff
    case autoRefreshSeconds
    case storageStatus
    case generalSettings
    case usdOption
    case cnyOption
    case agentActive
    case agentNotFound
    case agentRecords
    case currencySummary
    case exchangeRateSummary
    case exchangeRatePrefix
    case exchangeRatePlaceholder
    case currencyCNY
    case sqliteDatabase
    case versionLabel
    case localFirstPrivate
    case privacyDescription
    case openSource
    case github

    // Hero Card Metrics
    case freshInput
    case modelOutput
    case cacheWrite
    case cacheRead
    case cacheHitRate
    // Settings Navigation & Details
    case settingsNavGeneral
    case settingsNavAgents
    case settingsNavPricing
    case settingsNavStorage
    case settingsNavAbout
    case settingsGeneralSubtitle
    case settingsAgentsSubtitle
    case settingsPricingSubtitle
    case settingsStorageSubtitle
    case settingsAboutSubtitle

    // Update Checker
    case checkForUpdates
    case checkingForUpdates
    case updateCurrentVersion
    case updateUpToDate
    case updateAvailableTitle
    case updateAvailableMessage
    case downloadUpdate
    case viewReleaseNotes
    case skipThisVersion
    case updateSkippedNote
    case updateRestoreSkipped
    case autoCheckUpdatesLabel
    case autoCheckUpdatesSubtitle
    case updateLastChecked
    case updateNeverChecked
    case updateCheckFailed
    case updateErrorNetwork
    case updateErrorServer
    case updateErrorDecoding
    case updateErrorNoReleases
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
    .dashboardTitle: "Bennett Usage",
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
    .periodTokens: "Total Tokens",
    .todaysTokens: "Today's Tokens",
    .periodSpend: "Total Spend ($ / ¥)",
    .mostActiveAgent: "Most Active Agent",
    .totalTokensSuffix: "%@ Total",
    .spendSuffix: "%@ Spend",
    .leadingVolume: "Leading Volume",
    .none: "None",
    .rangeTokens: "%@ Tokens",

    // Heatmap Section
    .annualPanorama: "Annual Panorama",
    .annualTotalTokens: "Annual Tokens",
    .annualSpend: "Annual Spend",
    .annualActiveDays: "Active Days",
    .annualPrimaryAgent: "Top Agent",
    .viewAnnualDashboard: "Full Year View",
    .viewingAnnualDashboard: "Viewing Year %@",
    .exitAnnualDashboard: "Exit Year View",
    .heatmapView: "Heatmap View",
    .calendarView: "Calendar",
    .monthlyTrend: "Monthly Trend",
    .tokenActivity: "Token Activity (%@)",
    .tokenUnit: "tokens",
    .activeDaysCount: "%d active days",
    .activityOnDay: "Activity on %@",
    .activityDetail: "Total Tokens: %@ · Cost: %@",
    .less: "Less",
    .more: "More",
    .noTokenUsage: "%@: No token usage",

    // Breakdown & Charts
    .toolDistribution: "Tool Distribution",
    .modelDistribution: "Model Distribution",
    .toolShareBreakdown: "Tool Share Breakdown (%@)",
    .modelUsageBreakdown: "Model Usage Breakdown (%@)",
    .noToolData: "No tool data for %@",
    .noModelData: "No model data for %@",
    .noActivityRecorded: "No activity recorded for %@",
    .chartType: "Chart Type",
    .chartTypeBar: "Bar Chart",
    .chartTypeLine: "Line Chart",
    .hourlyTrendLast24h: "Hourly Token Trend (Last 24h)",
    .hourlyTrendToday: "Hourly Token Trend (Today)",
    .dailyTrendLast7Days: "Daily Token Trend (Last 7 Days)",
    .dailyTrendLast30Days: "Daily Token Trend (Last 30 Days)",
    .monthlyTrendPastYear: "Monthly Token Trend (Past Year)",
    .monthlyTrendYear: "Monthly Token Trend (%@)",

    // Top Projects
    .topProjectsDrillDown: "Top 100 Projects",
    .trackedProjectsCount: "Top %d of 100",
    .noProjectFoldersRecorded: "No project folders recorded yet",
    .tokensCount: "%@ tokens",
    .showMoreProjects: "Show %d More Directories",
    .showLess: "Show Less",
    // MenuBar Popover
    .estimatedCost: "Estimated Cost",
    .toolBreakdownToday: "Tool Breakdown (Today)",
    .noToolsActiveToday: "No tools active today",
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
    .allAgentsUsage: "All Agents Usage",
    .clearFocus: "Clear Focus",
    .agentHealthSection: "Agent Data Sources & Health Diagnostics",
    .pricingSection: "Pricing & Currency",
    .storageSection: "Storage & Maintenance",
    .exchangeRateLabel: "USD ⇄ CNY Exchange Rate",
    .preferredCurrencyLabel: "Preferred Currency",
    .revealInFinder: "Reveal in Finder",
    .rebuildRollups: "Rebuild Aggregates",
    .clearAllRecords: "Clear Local Usage Cache...",
    .clearRecordsConfirmTitle: "Clear Local Usage Cache?",
    .clearRecordsConfirmMessage: "This clears the locally aggregated usage statistics. Source agent logs are preserved and can be imported again on the next sync.",
    .rebuildRollupsDescription: "Re-aggregate token usage and daily summaries from locally stored records",
    .clearRecordsDescription: "Clear locally aggregated usage statistics; source agent logs are preserved for the next sync",
    .maintenanceSucceeded: "Maintenance completed successfully",
    .maintenanceFailed: "Maintenance failed. Please try again.",
    .autoRefreshLabel: "Auto Refresh Interval",
    .autoRefreshOff: "Manual",
    .autoRefreshSeconds: "%d seconds",
    .storageStatus: "%d records · %@ on disk",
    .generalSettings: "General Settings",
    .usdOption: "USD ($)",
    .cnyOption: "CNY (¥)",
    .agentActive: "Active",
    .agentNotFound: "Not Found",
    .agentRecords: "%d records",
    .currencySummary: "USD ($) / CNY (¥)",
    .exchangeRateSummary: "1 USD = %@ CNY",
    .exchangeRatePrefix: "1 USD =",
    .exchangeRatePlaceholder: "7.30",
    .currencyCNY: "CNY",
    .sqliteDatabase: "SQLite Database",
    .versionLabel: "v%@",
    .localFirstPrivate: "100% Local-First & Private",
    .privacyDescription: "All analytics and token logs are stored exclusively in your local SQLite database. Bennett Usage never collects, transmits, or inspects your source code, prompts, or API keys.",
    .openSource: "Open Source",
    .github: "GitHub",

    // Hero Card Metrics
    .freshInput: "Fresh Input",
    .modelOutput: "Output",
    .cacheWrite: "Cache Write",
    .cacheRead: "Cache Read",
    .cacheHitRate: "Cache Hit Rate",

    // Settings Navigation & Details
    .settingsNavGeneral: "General",
    .settingsNavAgents: "Agent Health",
    .settingsNavPricing: "Pricing & Currency",
    .settingsNavStorage: "Storage & Data",
    .settingsNavAbout: "About Bennett",
    .settingsGeneralSubtitle: "Language preferences and dashboard refresh interval",
    .settingsAgentsSubtitle: "Local AI agent detection, session logs, and health status",
    .settingsPricingSubtitle: "Reference exchange rates and primary currency display",
    .settingsStorageSubtitle: "Local database metrics, index rollups, and cache maintenance",
    .settingsAboutSubtitle: "Version details, privacy commitment, and repository links",

    // Update Checker
    .checkForUpdates: "Check for Updates",
    .checkingForUpdates: "Checking…",
    .updateCurrentVersion: "Version v%@",
    .updateUpToDate: "You're running the latest version",
    .updateAvailableTitle: "v%@ is now available",
    .updateAvailableMessage: "You're on v%@. Download the new build, or read the release notes first.",
    .downloadUpdate: "Download",
    .viewReleaseNotes: "Release Notes",
    .skipThisVersion: "Skip This Version",
    .updateSkippedNote: "Version v%@ is skipped",
    .updateRestoreSkipped: "Restore",
    .autoCheckUpdatesLabel: "Automatically Check for Updates",
    .autoCheckUpdatesSubtitle: "Query the public GitHub Releases feed once a day. No usage data is sent.",
    .updateLastChecked: "Last checked %@",
    .updateNeverChecked: "Not checked yet",
    .updateCheckFailed: "Couldn't check for updates",
    .updateErrorNetwork: "No network connection, or the update server is unreachable.",
    .updateErrorServer: "The update server returned HTTP %d.",
    .updateErrorDecoding: "The update server sent a response this version can't read.",
    .updateErrorNoReleases: "No published release with a usable version tag was found."
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
    .dashboardTitle: "Bennett Usage",
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
    .periodTokens: "总 Token",
    .todaysTokens: "今日 Token",
    .periodSpend: "总支出 ($ / ¥)",
    .mostActiveAgent: "最活跃 Agent",
    .totalTokensSuffix: "%@ 总计",
    .spendSuffix: "%@ 支出",
    .leadingVolume: "消耗占比最高",
    .none: "无",
    .rangeTokens: "%@ Token",

    // Heatmap Section
    .annualPanorama: "年度全景与活跃度",
    .annualTotalTokens: "年度总 Token",
    .annualSpend: "年度支出",
    .annualActiveDays: "活跃天数",
    .annualPrimaryAgent: "主力 Agent",
    .viewAnnualDashboard: "全盘年度分析",
    .viewingAnnualDashboard: "当前为 %@ 年全盘分析",
    .exitAnnualDashboard: "退出年度分析",
    .heatmapView: "热力图视图",
    .calendarView: "日历视图",
    .monthlyTrend: "月度趋势",
    .tokenActivity: "Token 活跃度 (%@)",
    .tokenUnit: "Token",
    .activeDaysCount: "%d 个活跃天数",
    .activityOnDay: "%@ 的活跃数据",
    .activityDetail: "总 Token: %@ · 费用: %@",
    .less: "少",
    .more: "多",
    .noTokenUsage: "%@: 无 Token 消耗",

    // Breakdown & Charts
    .toolDistribution: "工具分布",
    .modelDistribution: "模型分布",
    .toolShareBreakdown: "各工具消耗占比 (%@)",
    .modelUsageBreakdown: "各模型消耗占比 (%@)",
    .noToolData: "%@ 暂无工具数据",
    .noModelData: "%@ 暂无模型数据",
    .noActivityRecorded: "%@ 暂无活动记录",
    .chartType: "图表类型",
    .chartTypeBar: "柱状图",
    .chartTypeLine: "折线图",
    .hourlyTrendLast24h: "小时级 Token 趋势 (最近 24 小时)",
    .hourlyTrendToday: "小时级 Token 趋势 (今日)",
    .dailyTrendLast7Days: "日级 Token 趋势 (最近 7 天)",
    .dailyTrendLast30Days: "日级 Token 趋势 (最近 30 天)",
    .monthlyTrendPastYear: "月度 Token 趋势 (过去一年)",
    .monthlyTrendYear: "月度 Token 趋势 (%@)",

    // Top Projects
    .topProjectsDrillDown: "前 100 个项目",
    .trackedProjectsCount: "前 %d 个",
    .noProjectFoldersRecorded: "暂无已记录的项目目录",
    .tokensCount: "%@ tokens",
    .showMoreProjects: "展开更多 (剩余 %d 个目录)",
    .showLess: "收起目录",
    // MenuBar Popover
    .estimatedCost: "预估费用",
    .toolBreakdownToday: "工具分布 (今日)",
    .noToolsActiveToday: "今日暂无工具活动",
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
    .allAgentsUsage: "所有 Agent 用量",
    .clearFocus: "清除聚焦",
    .agentHealthSection: "Agent 数据源接入与状态诊断",
    .pricingSection: "计价与货币",
    .storageSection: "数据存储与维护",
    .exchangeRateLabel: "USD ⇄ CNY 参考汇率",
    .preferredCurrencyLabel: "主显示币种",
    .revealInFinder: "在访达中显示",
    .rebuildRollups: "重新聚合数据",
    .clearAllRecords: "清空本地统计缓存...",
    .clearRecordsConfirmTitle: "确定清空本地统计缓存？",
    .clearRecordsConfirmMessage: "此操作会清空本地统计缓存。Agent 原始日志会保留，并可在下次同步时重新导入。",
    .rebuildRollupsDescription: "根据本地记录重新聚合 Token 用量与每日汇总",
    .clearRecordsDescription: "清空本地统计缓存；Agent 原始日志会保留并在下次同步时重新导入",
    .maintenanceSucceeded: "维护操作已完成",
    .maintenanceFailed: "维护操作失败，请重试。",
    .autoRefreshLabel: "自动刷新频率",
    .autoRefreshOff: "手动刷新",
    .autoRefreshSeconds: "%d 秒",
    .storageStatus: "%d 条用量记录 · 占用空间约 %@",
    .generalSettings: "通用设置",
    .usdOption: "美元 USD ($)",
    .cnyOption: "人民币 CNY (¥)",
    .agentActive: "正常",
    .agentNotFound: "未找到",
    .agentRecords: "%d 条记录",
    .currencySummary: "美元 USD ($) / 人民币 CNY (¥)",
    .exchangeRateSummary: "1 USD = %@ CNY",
    .exchangeRatePrefix: "1 USD =",
    .exchangeRatePlaceholder: "7.30",
    .currencyCNY: "CNY",
    .sqliteDatabase: "SQLite 数据库",
    .versionLabel: "v%@",
    .localFirstPrivate: "100% 本地优先与隐私保护",
    .privacyDescription: "所有分析数据和 Token 日志仅存储在本地 SQLite 数据库中。Bennett Usage 不会收集、传输或检查你的源代码、提示词或 API 密钥。",
    .openSource: "开源项目",
    .github: "GitHub",

    // Hero Card Metrics
    .freshInput: "新增输入",
    .modelOutput: "模型输出",
    .cacheWrite: "缓存写入",
    .cacheRead: "缓存命中",
    .cacheHitRate: "缓存命中率",

    // Settings Navigation & Details
    .settingsNavGeneral: "通用设置",
    .settingsNavAgents: "Agent 状态",
    .settingsNavPricing: "计价与汇率",
    .settingsNavStorage: "数据与存储",
    .settingsNavAbout: "关于应用",
    .settingsGeneralSubtitle: "配置界面语言偏好与看板数据自动刷新频率",
    .settingsAgentsSubtitle: "本地各 AI 编程 Agent 日志路径与会话采集状态诊断",
    .settingsPricingSubtitle: "配置 USD 与 CNY 参考汇率换算与主货币显示",
    .settingsStorageSubtitle: "查看本地 SQLite 数据库状态、重建统计与数据清理",
    .settingsAboutSubtitle: "版本信息、100% 本地隐私保证与开源仓库信息",

    // Update Checker
    .checkForUpdates: "检查更新",
    .checkingForUpdates: "正在检查…",
    .updateCurrentVersion: "当前版本 v%@",
    .updateUpToDate: "当前已是最新版本",
    .updateAvailableTitle: "发现新版本 v%@",
    .updateAvailableMessage: "当前版本 v%@。可直接下载新版本，也可以先看更新日志。",
    .downloadUpdate: "下载更新",
    .viewReleaseNotes: "更新日志",
    .skipThisVersion: "跳过此版本",
    .updateSkippedNote: "已跳过 v%@",
    .updateRestoreSkipped: "恢复提醒",
    .autoCheckUpdatesLabel: "自动检查更新",
    .autoCheckUpdatesSubtitle: "每天向 GitHub Releases 公共接口查询一次版本，不发送任何本地数据。",
    .updateLastChecked: "上次检查：%@",
    .updateNeverChecked: "尚未检查",
    .updateCheckFailed: "检查更新失败",
    .updateErrorNetwork: "网络不可用，或无法连接更新服务器。",
    .updateErrorServer: "更新服务器返回 HTTP %d。",
    .updateErrorDecoding: "更新服务器返回的内容无法解析。",
    .updateErrorNoReleases: "未找到带有效版本号的已发布版本。"
]
