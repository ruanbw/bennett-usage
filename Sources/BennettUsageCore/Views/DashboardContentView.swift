import SwiftUI
import Charts
import AppKit

public enum TrendChartType: String, CaseIterable, Identifiable {
    case bar
    case line

    public var id: String { rawValue }

    static func accessibilityTitle(localization: LocalizationManager) -> String {
        localization.localized(.chartType)
    }

    func accessibilityLabel(localization: LocalizationManager) -> String {
        switch self {
        case .bar: return localization.localized(.chartTypeBar)
        case .line: return localization.localized(.chartTypeLine)
        }
    }
}

public enum HeatmapDisplayMode: String, CaseIterable, Identifiable {
    case calendar
    case monthlyTrend

    public var id: String { rawValue }

    static func accessibilityTitle(localization: LocalizationManager) -> String {
        localization.localized(.heatmapView)
    }

    func accessibilityLabel(localization: LocalizationManager) -> String {
        switch self {
        case .calendar: return localization.localized(.calendarView)
        case .monthlyTrend: return localization.localized(.monthlyTrend)
        }
    }
}

public struct DashboardContentView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager
    @ObservedObject var pricingEngine: PricingEngine
    public let onOpenSettings: (() -> Void)?

    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var periodMetrics: PeriodMetrics?
    @State private var selectedRange: TimeRangeOption
    @State private var availableYears: [Int] = []
    @State private var selectedCell: HeatmapDayCell?
    @State private var selectedToolFilter: String?
    @State private var agentNames: [String] = []
    /// Agents with recorded usage inside `selectedRange`, independent of the
    /// active filter. Feeds the filter bar; see `loadRangeActiveAgents()`.
    @State private var rangeActiveAgents: [String] = []
    @State private var cachedAgentColors: [String: Color] = [:]
    @State private var cachedModelColors: [String: Color] = [:]
    @State private var isProjectsExpanded: Bool = false
    @State private var refreshTick = 0
    @State private var updateThrottle = TrailingThrottle(interval: 1.0)
    @State private var selectedHeatmapYear: Int = Calendar.current.component(.year, from: Date())
    @State private var annualSummary: (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String, activeDays: Int, totalDays: Int)? = nil
    @State private var annualTrendPoints: [TrendPoint] = []
    @State private var heatmapDisplayMode: HeatmapDisplayMode = .calendar
    @State private var isSettingsHovered: Bool = false
    @State private var todaySummary: TodaySummary?
    @State private var lastDataRefreshAt: Date?

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared,
        initialRange: TimeRangeOption = .last24Hours,
        onOpenSettings: (() -> Void)? = nil,
        pricingEngine: PricingEngine = .shared
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.pricingEngine = pricingEngine
        self._selectedRange = State(initialValue: initialRange)
        self.onOpenSettings = onOpenSettings
        if case .year(let y) = initialRange {
            self._selectedHeatmapYear = State(initialValue: y)
        } else {
            self._selectedHeatmapYear = State(initialValue: Calendar.current.component(.year, from: Date()))
        }
    }

    // MARK: - Computed Helpers

    private var rangeSubtitle: String {
        Self.rangeTitle(for: selectedRange, localization: localization)
    }

    private var trendTitle: String {
        switch selectedRange {
        case .last24Hours: return localization.localized(.hourlyTrendLast24h)
        case .today: return localization.localized(.hourlyTrendToday)
        case .last7Days: return localization.localized(.dailyTrendLast7Days)
        case .last30Days: return localization.localized(.dailyTrendLast30Days)
        case .pastYear: return localization.localized(.monthlyTrendPastYear)
        case .year(let y): return localization.localized(.monthlyTrendYear, arguments: String(y))
        }
    }

    private var heatmapTitle: String {
        return localization.localized(.yearTitle, arguments: String(selectedHeatmapYear))
    }

    private var toolDistribution: [(tool: String, tokens: Int, costUSD: Double)] {
        periodMetrics?.toolDistribution ?? []
    }
    private var modelDistribution: [(model: String, tokens: Int, costUSD: Double)] {
        periodMetrics?.modelDistribution ?? []
    }

    private var projectRankings: [(project: String, totalTokens: Int, costUSD: Double)] {
        Array((periodMetrics?.projectRankings ?? []).prefix(MetricsAggregator.projectRankingLimit))
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Layout.sectionSpacing) {
                headerSection
                agentFilterSection
                heroSection
                TrendChartCard(
                    trendPoints: periodMetrics?.trendPoints ?? [],
                    trendTitle: trendTitle,
                    rangeSubtitle: rangeSubtitle,
                    modelColors: cachedModelColors,
                    localization: localization,
                    pricingEngine: pricingEngine
                )
                todayFocusSection
                distributionChartsSection
                heatmapSection
                projectsSection
                dataFreshnessFooter
            }
            .padding(AppTheme.Layout.canvasPadding)
        }
        .background(AppTheme.Canvas.background)
        .task(id: RefreshKey(scope: .period, range: selectedRange, year: nil, toolFilter: selectedToolFilter, tick: refreshTick)) {
            await loadPeriodMetrics()
        }
        .task(id: RefreshKey(scope: .agents, range: selectedRange, year: nil, toolFilter: nil, tick: refreshTick)) {
            await loadRangeActiveAgents()
        }
        .task(id: RefreshKey(scope: .annual, range: nil, year: selectedHeatmapYear, toolFilter: selectedToolFilter, tick: refreshTick)) {
            await loadAnnualSummaryData()
        }
        .task(id: Self.yearListRefreshKey(tick: refreshTick)) {
            await loadAvailableYears()
        }
        .task(id: RefreshKey(scope: .today, range: .today, year: nil, toolFilter: selectedToolFilter, tick: refreshTick)) {
            await loadTodaySummary()
        }
        .task {
            await autoRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bennettUsageDataDidUpdate)) { _ in
            lastDataRefreshAt = Date()
            guard dashboardWindowIsVisible() else { return }
            Task { await loadDataThrottled() }
        }
    }

    // MARK: - Header (Time Tabs on Left, Year Dropdown on Right)

    private var displayedYears: [Int] {
        if availableYears.isEmpty {
            return [Calendar.current.component(.year, from: Date())]
        }
        return availableYears
    }

    static let dashboardTimeRanges: [TimeRangeOption] = [
        .last24Hours,
        .today,
        .last7Days,
        .last30Days,
        .pastYear
    ]

    /// The full year entered from the annual panorama remains selectable in the
    /// compact menu after the toolbar folds.
    static func dashboardTimeRanges(including selectedRange: TimeRangeOption) -> [TimeRangeOption] {
        var ranges = dashboardTimeRanges
        if case .year = selectedRange {
            ranges.append(selectedRange)
        }
        return ranges
    }

    static func rangeTitle(
        for range: TimeRangeOption,
        localization: LocalizationManager
    ) -> String {
        switch range {
        case .last24Hours: return localization.localized(.range24h)
        case .today: return localization.localized(.rangeToday)
        case .last7Days: return localization.localized(.range7Days)
        case .last30Days: return localization.localized(.range30Days)
        case .pastYear: return localization.localized(.range1Year)
        case .year(let year): return String(year)
        }
    }

    private func rangePill(_ option: TimeRangeOption, title: String) -> some View {
        let isSelected = selectedRange == option
        return Button {
            selectedRange = option
        } label: {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? AppTheme.Surface.primary : Color.clear)
                        .shadow(color: Color.black.opacity(isSelected ? 0.04 : 0), radius: 1.5, x: 0, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var fullRangePicker: some View {
        HStack(spacing: 2) {
            ForEach(Self.dashboardTimeRanges, id: \.self) { range in
                rangePill(
                    range,
                    title: Self.rangeTitle(for: range, localization: localization)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Surface.subtle)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactRangeMenu: some View {
        Menu {
            ForEach(Self.dashboardTimeRanges(including: selectedRange), id: \.self) { range in
                Button(Self.rangeTitle(for: range, localization: localization)) {
                    selectedRange = range
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(rangeSubtitle)
                    .font(.caption)
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundColor(AppTheme.Text.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Surface.subtle)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var responsiveRangePicker: some View {
        ViewThatFits(in: .horizontal) {
            fullRangePicker
            compactRangeMenu
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            responsiveRangePicker

            if case .year(let y) = selectedRange {
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11))
                    Text(localization.localized(.viewingAnnualDashboard, arguments: String(y)))
                        .font(AppTheme.Typography.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Button {
                        selectedRange = .last30Days
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help(localization.localized(.exitAnnualDashboard))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Surface.selected)
                )
                .foregroundColor(AppTheme.Status.accent)
            }

            Spacer(minLength: 8)

            if let onOpenSettings = onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.Control.icon, weight: .medium))
                        .foregroundColor(isSettingsHovered ? AppTheme.Text.primary : AppTheme.Text.secondary)
                        .frame(width: AppTheme.Control.compactHeight, height: AppTheme.Control.compactHeight)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                .fill(isSettingsHovered ? AppTheme.Surface.hover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isSettingsHovered = hovering
                }
                .help(localization.localized(.settings))
                .accessibilityLabel(localization.localized(.settings))
            }
        }
    }

    // MARK: - Agent Filter

    private var agentFilterSection: some View {
        AgentFilterBarView(
            selectedAgent: selectedToolFilter,
            availableAgents: agentNames,
            localization: localization
        ) { agent in
            selectedToolFilter = agent
            selectedCell = nil
        }
    }

    // MARK: - Hero KPI & Metrics Ribbon

    private var heroSection: some View {
        VStack(spacing: 16) {
            heroTopRow

            AppTheme.Border.divider
                .frame(height: AppTheme.Layout.hairline)

            heroMetricsRibbon
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .stroke(AppTheme.Border.subtle, lineWidth: AppTheme.Layout.hairline)
        )
    }

    private var heroTopRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                heroTotalMetric
                Spacer(minLength: 12)
                heroSpendMetric
            }
            VStack(alignment: .leading, spacing: 14) {
                heroTotalMetric
                heroSpendMetric
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var heroTotalMetric: some View {
        let agentDotColor = selectedToolFilter.flatMap { AgentFilterBarView.colorMap[$0] ?? cachedAgentColors[$0] } ?? AppTheme.Status.accent
        let agentTitle = selectedToolFilter.map { AgentFilterBarView.displayName(for: $0) }
            ?? localization.localized(.allAgentsUsage)
        let totalTokens = periodMetrics?.totalTokens ?? 0

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(agentDotColor)
                    .frame(width: 7, height: 7)
                Text(agentTitle)
                    .font(AppTheme.Typography.label)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
            }

            Text(TokenFormatter.formatCompact(totalTokens))
                .font(AppTheme.Typography.heroMetric)
                .foregroundColor(AppTheme.Text.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText())

            Text("\(TokenFormatter.formatFull(totalTokens)) \(localization.localized(.tokenUnit))")
                .font(AppTheme.Typography.exactValue)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help("\(TokenFormatter.formatFull(totalTokens)) \(localization.localized(.tokenUnit))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agentTitle), \(TokenFormatter.formatFull(totalTokens)) \(localization.localized(.tokenUnit))")
    }

    private var heroSpendMetric: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(localization.localized(.spendSuffix, arguments: rangeSubtitle))
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)

            Text(pricingEngine.spendString(periodMetrics?.totalCostUSD ?? 0.0))
                .font(AppTheme.Typography.heroSpend)
                .foregroundColor(AppTheme.Status.success)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(AppTheme.Surface.subtle.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
    }

    private var heroMetricsRibbon: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                ribbonMetricColumn(
                    label: localization.localized(.freshInput),
                    value: TokenFormatter.formatCompact(periodMetrics?.inputTokens ?? 0),
                    fullTokens: periodMetrics?.inputTokens ?? 0
                )

                Divider().frame(height: 24).opacity(0.3)

                ribbonMetricColumn(
                    label: localization.localized(.modelOutput),
                    value: TokenFormatter.formatCompact(periodMetrics?.outputTokens ?? 0),
                    fullTokens: periodMetrics?.outputTokens ?? 0
                )

                Divider().frame(height: 24).opacity(0.3)

                ribbonMetricColumn(
                    label: localization.localized(.cacheWrite),
                    value: TokenFormatter.formatCompact(periodMetrics?.cacheWriteTokens ?? 0),
                    fullTokens: periodMetrics?.cacheWriteTokens ?? 0
                )

                Divider().frame(height: 24).opacity(0.3)

                ribbonMetricColumn(
                    label: localization.localized(.cacheRead),
                    value: TokenFormatter.formatCompact(periodMetrics?.cacheReadTokens ?? 0),
                    fullTokens: periodMetrics?.cacheReadTokens ?? 0
                )

                Divider().frame(height: 24).opacity(0.3)

                ribbonCacheHitRateColumn
            }
            tokenCompositionBar
        }
    }

    /// Token composition is derived exclusively from the four first-class
    /// PeriodMetrics counters. It intentionally does not reuse the model
    /// distribution, whose rows may represent a top-N subset.
    private var tokenCompositionBar: some View {
        let input = periodMetrics?.inputTokens ?? 0
        let output = periodMetrics?.outputTokens ?? 0
        let cacheRead = periodMetrics?.cacheReadTokens ?? 0
        let cacheWrite = periodMetrics?.cacheWriteTokens ?? 0
        let total = max(0, input + output + cacheRead + cacheWrite)
        let segments: [(id: String, tokens: Int, color: Color)] = [
            ("input", input, AppTheme.Status.accent),
            ("output", output, AppTheme.Agent.claude),
            ("cacheRead", cacheRead, AppTheme.Status.success),
            ("cacheWrite", cacheWrite, AppTheme.Agent.copilot)
        ]

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.Surface.subtle)
                HStack(spacing: 0) {
                    ForEach(segments, id: \.id) { segment in
                        if segment.tokens > 0, total > 0 {
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: proxy.size.width * CGFloat(segment.tokens) / CGFloat(total))
                        }
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.localized(.rangeTokens, arguments: TokenFormatter.formatFull(total)))
    }

    private func ribbonMetricColumn(label: String, value: String, fullTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(value)
                .font(AppTheme.Typography.metricValue)
                .foregroundColor(AppTheme.Text.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Color.clear
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(TokenFormatter.formatFull(fullTokens)) \(localization.localized(.tokenUnit))")
    }

    private var ribbonCacheHitRateColumn: some View {
        let hitRate = periodMetrics?.cacheHitRate ?? 0.0
        return VStack(alignment: .leading, spacing: 4) {
            Text(localization.localized(.cacheHitRate))
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(String(format: "%.1f%%", hitRate * 100))
                .font(AppTheme.Typography.metricValue)
                .foregroundColor(AppTheme.Text.primary)
                .monospacedDigit()
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Surface.subtle)
                        .frame(height: 3)
                    Capsule()
                        .fill(AppTheme.Status.success)
                        .frame(width: max(0, min(geo.size.width * CGFloat(hitRate), geo.size.width)), height: 3)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(localization.localized(.cacheHitRate) + ": " + String(format: "%.1f%%", hitRate * 100))
    }

    // MARK: - Heatmap

    // MARK: - Annual Panorama & Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row: Title & Subtitle on Left, Controls on Right
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .foregroundColor(AppTheme.Status.accent)
                            .font(.headline)
                        Text(localization.localized(.annualPanorama))
                            .font(.headline)
                            .foregroundColor(AppTheme.Text.primary)
                    }
                    Text("\(String(selectedHeatmapYear))-01-01 ~ \(String(selectedHeatmapYear))-12-31")
                        .font(.caption2)
                        .foregroundColor(AppTheme.Text.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    // Year Switcher Pills (or Menu if > 4 years)
                    if displayedYears.count <= 4 {
                        HStack(spacing: 2) {
                            ForEach(displayedYears, id: \.self) { year in
                                let isSelected = selectedHeatmapYear == year
                                Button {
                                    selectedHeatmapYear = year
                                    selectedCell = nil
                                } label: {
                                    Text(String(year))
                                        .font(.caption)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? AppTheme.Surface.primary : Color.clear)
                                                .shadow(color: Color.black.opacity(isSelected ? 0.04 : 0), radius: 1.5, x: 0, y: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(AppTheme.Surface.subtle)
                        )
                    } else {
                        Menu {
                            ForEach(displayedYears, id: \.self) { year in
                                Button(String(year)) {
                                    selectedHeatmapYear = year
                                    selectedCell = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(selectedHeatmapYear)).bold()
                                    .foregroundColor(AppTheme.Text.primary)
                                Image(systemName: "chevron.down").font(.caption2)
                                    .foregroundColor(AppTheme.Text.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(AppTheme.Surface.subtle)
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    // Display Mode Switcher (Calendar vs Monthly Trend)
                    Picker(
                        HeatmapDisplayMode.accessibilityTitle(localization: localization),
                        selection: $heatmapDisplayMode
                    ) {
                        Image(systemName: "square.grid.3x3.fill")
                            .help(localization.localized(.calendarView))
                            .accessibilityLabel(HeatmapDisplayMode.calendar.accessibilityLabel(localization: localization))
                            .tag(HeatmapDisplayMode.calendar)
                        Image(systemName: "chart.bar.xaxis")
                            .help(localization.localized(.monthlyTrend))
                            .accessibilityLabel(HeatmapDisplayMode.monthlyTrend.accessibilityLabel(localization: localization))
                            .tag(HeatmapDisplayMode.monthlyTrend)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 66)

                    // Apply to Dashboard Button
                    let isFullDashboardYear = (selectedRange == .year(selectedHeatmapYear))
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isFullDashboardYear {
                                selectedRange = .last30Days
                            } else {
                                selectedRange = .year(selectedHeatmapYear)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isFullDashboardYear ? "checkmark.circle.fill" : "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                            Text(isFullDashboardYear
                                ? localization.localized(.viewingAnnualDashboard, arguments: String(selectedHeatmapYear))
                                : localization.localized(.viewAnnualDashboard)
                            )
                            .font(.caption)
                            .fontWeight(isFullDashboardYear ? .semibold : .regular)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isFullDashboardYear ? AppTheme.Surface.selected : AppTheme.Surface.subtle)
                        .foregroundColor(isFullDashboardYear ? AppTheme.Status.accent : AppTheme.Text.secondary)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isFullDashboardYear ? AppTheme.Status.accent.opacity(0.3) : AppTheme.Border.subtle, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(isFullDashboardYear ? localization.localized(.exitAnnualDashboard) : localization.localized(.viewAnnualDashboard))
                }
            }

            // Annual Key Metrics Strip
            if let summary = annualSummary {
                annualMetricsStrip(summary: summary)
            }

            // Visualization Content
            if heatmapDisplayMode == .calendar {
                HeatmapGridView(
                    cells: heatmapCells,
                    selectedDayKey: selectedCell?.dayKey,
                    localization: localization,
                    pricingEngine: pricingEngine
                ) { cell in
                    selectedCell = (selectedCell?.dayKey == cell.dayKey) ? nil : cell
                }

                if let cell = selectedCell, cell.totalTokens > 0 {
                    dayInspectionBanner(cell: cell)
                }
            } else {
                AnnualMonthlyTrendCard(
                    annualTrendPoints: annualTrendPoints,
                    selectedHeatmapYear: selectedHeatmapYear,
                    localization: localization,
                    pricingEngine: pricingEngine
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
    }

    private func annualMetricsStrip(summary: (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String, activeDays: Int, totalDays: Int)) -> some View {
        HStack(spacing: 0) {
            // 1. Annual Tokens
            annualStatItem(
                title: localization.localized(.annualTotalTokens),
                value: TokenFormatter.formatCompact(summary.annualTokens),
                subvalue: "\(TokenFormatter.formatFull(summary.annualTokens)) tokens",
                icon: "flame.fill",
                color: AppTheme.Status.warning
            )
            Divider().frame(height: 24).opacity(0.3).padding(.horizontal, 8)

            // 2. Annual Cost
            annualStatItem(
                title: localization.localized(.annualSpend),
                value: pricingEngine.spendString(summary.annualCostUSD),
                subvalue: summary.annualCostUSD > 0 ? (pricingEngine.preferredCurrency == .cny ? "CNY" : "USD") : "-",
                icon: "dollarsign.circle.fill",
                color: AppTheme.Status.success
            )
            Divider().frame(height: 24).opacity(0.3).padding(.horizontal, 8)

            // 3. Active Days
            let pct = summary.totalDays > 0 ? (Double(summary.activeDays) / Double(summary.totalDays) * 100.0) : 0.0
            annualStatItem(
                title: localization.localized(.annualActiveDays),
                value: "\(summary.activeDays) / \(summary.totalDays)",
                subvalue: String(format: "%.1f%%", pct),
                icon: "calendar.badge.checkmark",
                color: AppTheme.Status.accent
            )
            Divider().frame(height: 24).opacity(0.3).padding(.horizontal, 8)

            // 4. Primary Agent
            let agentName = summary.mostActiveTool != "None" ? AgentFilterBarView.displayName(for: summary.mostActiveTool) : localization.localized(.none)
            let agentColor = summary.mostActiveTool != "None" ? (cachedAgentColors[summary.mostActiveTool] ?? AppTheme.Status.accent) : AppTheme.Text.secondary
            annualStatItem(
                title: localization.localized(.annualPrimaryAgent),
                value: agentName,
                subvalue: summary.annualTokens > 0 ? localization.localized(.leadingVolume) : "-",
                icon: "sparkles",
                color: agentColor
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Surface.subtle)
        )
    }

    private func annualStatItem(title: String, value: String, subvalue: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(AppTheme.Text.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(AppTheme.Text.primary)
                    Text(subvalue)
                        .font(.caption2)
                        .foregroundColor(AppTheme.Text.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func dayInspectionBanner(cell: HeatmapDayCell) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localization.localized(.activityOnDay, arguments: cell.dayKey))
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(AppTheme.Text.primary)
                Spacer()
                Button {
                    selectedCell = nil
                } label: {
                    HStack(spacing: 3) {
                        Text(localization.localized(.clearFocus))
                            .font(.caption)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .foregroundColor(AppTheme.Text.secondary)
                }
                .buttonStyle(.plain)
            }
            let formattedTokens = "\(TokenFormatter.formatCompact(cell.totalTokens)) (\(TokenFormatter.formatFull(cell.totalTokens)))"
            Text(localization.localized(
                .activityDetail,
                arguments: formattedTokens,
                pricingEngine.spendString(cell.costUSD)
            ))
                .font(.caption)
                .foregroundColor(AppTheme.Text.secondary)
            if !cell.toolBreakdown.isEmpty {
                HStack(spacing: 8) {
                    ForEach(cell.toolBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { tool, count in
                        let color = cachedAgentColors[tool] ?? AppTheme.Text.tertiary
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatCompact(count))")
                                .font(.caption)
                                .foregroundColor(AppTheme.Text.primary)
                                .help("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatFull(count)) tokens")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppTheme.Surface.primary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Surface.subtle)
        )
    }

    // MARK: - Today Focus

    private var todayFocusSection: some View {
        let summary = todaySummary
        let activeTools = MenuBarPopoverView.activeTools(for: summary)
        let topAgent = activeTools.first
        let totalTokens = summary?.totalTokens ?? 0
        let totalCost = summary?.totalCostUSD ?? 0.0

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 0) {
                todayFocusMetric(
                    title: localization.localized(.todaysTokens),
                    value: TokenFormatter.formatCompact(totalTokens),
                    detail: TokenFormatter.formatFull(totalTokens),
                    symbol: "sparkles",
                    color: AppTheme.Status.accent
                )
                focusDivider
                todayFocusMetric(
                    title: localization.localized(.estimatedCost),
                    value: pricingEngine.spendString(totalCost),
                    detail: nil,
                    symbol: "dollarsign.circle",
                    color: AppTheme.Status.success
                )
                focusDivider
                todayFocusMetric(
                    title: localization.localized(.mostActiveAgent),
                    value: topAgent.map { AgentFilterBarView.displayName(for: $0.id) } ?? localization.localized(.none),
                    detail: topAgent.map { TokenFormatter.formatCompact($0.tokens) },
                    symbol: "bolt.fill",
                    color: topAgent.flatMap { cachedAgentColors[$0.id] } ?? AppTheme.Text.secondary
                )
            }
            VStack(alignment: .leading, spacing: 12) {
                todayFocusMetric(
                    title: localization.localized(.todaysTokens),
                    value: TokenFormatter.formatCompact(totalTokens),
                    detail: TokenFormatter.formatFull(totalTokens),
                    symbol: "sparkles",
                    color: AppTheme.Status.accent
                )
                focusDivider
                todayFocusMetric(
                    title: localization.localized(.estimatedCost),
                    value: pricingEngine.spendString(totalCost),
                    detail: nil,
                    symbol: "dollarsign.circle",
                    color: AppTheme.Status.success
                )
                focusDivider
                todayFocusMetric(
                    title: localization.localized(.mostActiveAgent),
                    value: topAgent.map { AgentFilterBarView.displayName(for: $0.id) } ?? localization.localized(.none),
                    detail: topAgent.map { TokenFormatter.formatCompact($0.tokens) },
                    symbol: "bolt.fill",
                    color: topAgent.flatMap { cachedAgentColors[$0.id] } ?? AppTheme.Text.secondary
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .stroke(AppTheme.Border.subtle, lineWidth: AppTheme.Layout.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.localized(.todaysTokens))
    }

    private var focusDivider: some View {
        AppTheme.Border.divider
            .frame(width: AppTheme.Layout.hairline, height: 42)
    }

    private func todayFocusMetric(
        title: String,
        value: String,
        detail: String?,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(AppTheme.Typography.metricValue)
                        .foregroundColor(AppTheme.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(AppTheme.Text.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Distribution Charts

    private var distributionChartsSection: some View {
        let activeTools = toolDistribution.filter { $0.tokens > 0 }
        let toolItems: [ProportionalDistributionCard.Item] = activeTools.map { item in
            (
                id: item.tool,
                name: AgentFilterBarView.displayName(for: item.tool),
                tokens: item.tokens,
                costUSD: item.costUSD,
                color: cachedAgentColors[item.tool] ?? .gray
            )
        }
        let totalToolTokens = toolItems.reduce(0) { $0 + $1.tokens }

        let activeModels = modelDistribution.filter { $0.tokens > 0 }
        let modelItems: [ProportionalDistributionCard.Item] = activeModels.map { item in
            (
                id: item.model,
                name: item.model,
                tokens: item.tokens,
                costUSD: item.costUSD,
                color: cachedModelColors[item.model] ?? .gray
            )
        }
        let totalModelTokens = modelItems.reduce(0) { $0 + $1.tokens }

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ProportionalDistributionCard(
                    title: localization.localized(.toolDistribution),
                    subtitle: rangeSubtitle,
                    items: toolItems,
                    totalTokens: totalToolTokens,
                    localization: localization,
                    emptyMessage: localization.localized(.noToolData, arguments: rangeSubtitle),
                    emptyIcon: "wrench.and.screwdriver",
                    pricingEngine: pricingEngine
                )
                ProportionalDistributionCard(
                    title: localization.localized(.modelDistribution),
                    subtitle: rangeSubtitle,
                    items: modelItems,
                    totalTokens: totalModelTokens,
                    localization: localization,
                    emptyMessage: localization.localized(.noModelData, arguments: rangeSubtitle),
                    emptyIcon: "cpu",
                    pricingEngine: pricingEngine
                )
            }
            VStack(spacing: 16) {
                ProportionalDistributionCard(
                    title: localization.localized(.toolDistribution),
                    subtitle: rangeSubtitle,
                    items: toolItems,
                    totalTokens: totalToolTokens,
                    localization: localization,
                    emptyMessage: localization.localized(.noToolData, arguments: rangeSubtitle),
                    emptyIcon: "wrench.and.screwdriver",
                    pricingEngine: pricingEngine
                )
                ProportionalDistributionCard(
                    title: localization.localized(.modelDistribution),
                    subtitle: rangeSubtitle,
                    items: modelItems,
                    totalTokens: totalModelTokens,
                    localization: localization,
                    emptyMessage: localization.localized(.noModelData, arguments: rangeSubtitle),
                    emptyIcon: "cpu",
                    pricingEngine: pricingEngine
                )
            }
        }
    }

    private var dataFreshnessFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(dataFreshnessText)
                .font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundColor(AppTheme.Text.tertiary)
        .padding(.top, -8)
        .accessibilityElement(children: .combine)
    }

    private var dataFreshnessText: String {
        guard let lastDataRefreshAt else {
            return localization.localized(.noTokenUsage, arguments: rangeSubtitle)
        }
        let minutes = max(0, Int(Date().timeIntervalSince(lastDataRefreshAt) / 60))
        if minutes == 0 {
            return localization.localized(.dataUpdatedJustNow)
        }
        return localization.localized(.dataUpdatedMinutesAgo, arguments: minutes)
    }

    // MARK: - Top Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localization.localized(.topProjectsDrillDown))
                    .font(.headline)
                    .foregroundColor(AppTheme.Text.primary)
                Spacer()
                Text(localization.localized(.trackedProjectsCount, arguments: projectRankings.count))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
            }

            if projectRankings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundColor(AppTheme.Text.tertiary.opacity(0.5))
                    Text(localization.localized(.noProjectFoldersRecorded))
                        .foregroundColor(AppTheme.Text.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                let maxTokens = max(projectRankings.first?.totalTokens ?? 1, 1)
                let displayedProjects = isProjectsExpanded ? projectRankings : Array(projectRankings.prefix(3))
                LazyVStack(spacing: 8) {
                    ForEach(Array(displayedProjects.enumerated()), id: \.element.project) { index, item in
                        let rank = index + 1
                        HStack(spacing: 12) {
                            medalBadge(rank: rank)
                                .frame(width: 20, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                let folderName = (item.project as NSString).lastPathComponent.isEmpty ? item.project : (item.project as NSString).lastPathComponent
                                Text(folderName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(AppTheme.Text.primary)
                                    .lineLimit(1)
                                    .help(item.project)
                                GeometryReader { geo in
                                    let ratio = CGFloat(item.totalTokens) / CGFloat(maxTokens)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(AppTheme.Surface.subtle)
                                        Capsule().fill(AppTheme.Rank.color(for: rank))
                                            .frame(width: max(4, geo.size.width * ratio))
                                    }
                                }
                                .frame(height: 3)
                            }

                            Spacer(minLength: 20)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(localization.localized(.tokensCount, arguments: TokenFormatter.formatCompact(item.totalTokens)))
                                    .font(.subheadline)
                                    .bold()
                                    .monospacedDigit()
                                    .foregroundColor(AppTheme.Text.primary)
                                    .help("\(TokenFormatter.formatFull(item.totalTokens)) tokens")
                                Text(pricingEngine.spendString(item.costUSD))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundColor(AppTheme.Text.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AppTheme.Surface.subtle.opacity(0.5))
                        )
                    }

                    if projectRankings.count > 3 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isProjectsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isProjectsExpanded
                                    ? localization.localized(.showLess)
                                    : localization.localized(.showMoreProjects, arguments: projectRankings.count - 3)
                                )
                                .font(.caption)
                                .fontWeight(.medium)
                                Image(systemName: isProjectsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundColor(AppTheme.Status.accent)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func medalBadge(rank: Int) -> some View {
        Text(String(format: "%02d", rank))
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(AppTheme.Rank.color(for: rank))
    }

    private func kpiCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(color)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3).bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    /// Data-update notifications can arrive in bursts while agents are active;
    /// each full `loadData` re-aggregates every record in range, so collapse
    /// bursts into at most one reload per second with a trailing edge: a
    /// notification arriving inside the window schedules exactly one follow-up
    /// instead of being dropped (dropping starved the UI under continuous
    /// activity and made project/token counts look stale or jumpy).
    private func loadDataThrottled() async {
        if updateThrottle.shouldRunImmediately() {
            await loadData()
            return
        }
        guard updateThrottle.shouldScheduleTrailer() else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        updateThrottle.trailerFired()
        await loadData()
    }

    // MARK: - Data Loading
    //
    // The refresh work is split into four independent `.task(id:)` pipelines so
    // that changing one dimension (range / heatmap year / tool filter) only
    // re-runs the queries that actually depend on it (U-02 / U-41):
    //
    //   • period  → selectedRange,       selectedToolFilter, refreshTick
    //   • agents  → selectedRange,                           refreshTick
    //   • annual  → selectedHeatmapYear, selectedToolFilter, refreshTick
    //   • years   →                                         refreshTick
    //
    // `agentNames` (the range-scoped filter options) is derived from
    // `rangeActiveAgents` + `selectedToolFilter`, and the cached palettes are
    // fixed/period-derived, so the period and agents pipelines each call the
    // shared, synchronous `refreshDerivedToolState()` once their own results are
    // published. Every `@State` write lives on the main actor and that helper
    // has no suspension point, so the callers can never interleave half-way
    // through an update; whichever call runs last always observes a
    // fully-updated pair of inputs, so the final derived value is independent of
    // completion order and there is no race on the assigned state.

    /// Scope discriminator for the dimension-scoped refresh tasks. A structured
    /// `Hashable` key (rather than a concatenated string) keeps each task's id
    /// free of unrelated dimensions and avoids per-body string interpolation.
    enum RefreshScope: Hashable {
        case period
        case agents
        case annual
        case years
        case today
    }

    struct RefreshKey: Hashable {
        let scope: RefreshScope
        let range: TimeRangeOption?
        let year: Int?
        let toolFilter: String?
        let tick: Int
    }

    /// The available-year list is independent of both the active filter and the
    /// selected range. Keeping the key construction here makes that contract
    /// explicit and directly testable.
    static func yearListRefreshKey(tick: Int) -> RefreshKey {
        RefreshKey(scope: .years, range: nil, year: nil, toolFilter: nil, tick: tick)
    }

    /// Filter-bar options for one range: every agent that recorded usage in it,
    /// plus the active filter (if any). Keeping the selected agent in the list
    /// even when the new range has no usage for it means switching ranges never
    /// makes an active filter silently vanish — its pill stays visible and
    /// clickable so the user can see and clear what is being filtered.
    static func agentFilterOptions(activeAgents: [String], selectedAgent: String?) -> [String] {
        var options = Set(activeAgents)
        if let selectedAgent, !selectedAgent.isEmpty,
           !options.contains(where: { $0.caseInsensitiveCompare(selectedAgent) == .orderedSame }) {
            options.insert(selectedAgent)
        }
        return options.sorted()
    }

    /// Recompute the range-scoped filter options and the agent/model palettes
    /// from the *current* state. Must stay synchronous (no `await`) so no other
    /// refresh task can interleave with it.
    private func refreshDerivedToolState() {
        let options = Self.agentFilterOptions(activeAgents: rangeActiveAgents, selectedAgent: selectedToolFilter)
        if options != agentNames {
            agentNames = options
        }
        // The agent palette is the fixed all-agents map, not a map over the
        // currently offered pills: the pill list shrinks with the range, and
        // recoloring surviving agents on every range switch would make the same
        // tool change color between the pills, the donut and the heatmap.
        let agentColors = AgentFilterBarView.colorMap
        if agentColors != cachedAgentColors {
            cachedAgentColors = agentColors
        }
        let modelColors = ChartPalette.shared.colors(for: (periodMetrics?.modelDistribution ?? []).map(\.model))
        if modelColors != cachedModelColors {
            cachedModelColors = modelColors
        }
    }

    /// `selectedRange` / `selectedToolFilter` dependents.
    private func loadPeriodMetrics() async {
        let range = selectedRange
        let toolFilter = selectedToolFilter
        let metrics = try? await aggregator.fetchPeriodMetrics(
            range: range,
            toolFilter: toolFilter,
            localization: localization
        )
        if Task.isCancelled { return }
        if metrics != periodMetrics {
            periodMetrics = metrics
        }
        refreshDerivedToolState()
    }

    /// `selectedRange` dependents that ignore the active filter: which agents
    /// the filter bar may offer. Deliberately unfiltered — deriving the options
    /// from the filtered `periodMetrics` would collapse the bar to the single
    /// selected agent, and deriving them from the annual heatmap (as this used
    /// to) leaked agents that were only active elsewhere in the year into a
    /// narrow range such as "Today".
    private func loadRangeActiveAgents() async {
        let range = selectedRange
        let tools = (try? await aggregator.fetchActiveTools(range: range)) ?? []
        if Task.isCancelled { return }
        if tools != rangeActiveAgents {
            rangeActiveAgents = tools
        }
        refreshDerivedToolState()
    }

    /// `selectedHeatmapYear` / `selectedToolFilter` dependents — the "annual
    /// trio": heatmap cells, annual summary and annual trend.
    private func loadAnnualSummaryData() async {
        let year = selectedHeatmapYear
        let toolFilter = selectedToolFilter
        let cells = (try? await aggregator.fetchAnnualHeatmap(year: year, toolFilter: toolFilter)) ?? []
        if Task.isCancelled { return }
        let summary = try? await aggregator.fetchAnnualSummary(year: year, toolFilter: toolFilter)
        if Task.isCancelled { return }
        let annualMetrics = try? await aggregator.fetchPeriodMetrics(
            range: .year(year),
            toolFilter: toolFilter,
            localization: localization
        )
        if Task.isCancelled { return }
        if cells != heatmapCells {
            heatmapCells = cells
        }
        // Tuples are not Equatable; compare field-wise before assigning so an
        // unchanged year does not invalidate the whole heatmap section.
        if summary?.annualTokens != annualSummary?.annualTokens
            || summary?.annualCostUSD != annualSummary?.annualCostUSD
            || summary?.mostActiveTool != annualSummary?.mostActiveTool
            || summary?.activeDays != annualSummary?.activeDays
            || summary?.totalDays != annualSummary?.totalDays {
            annualSummary = summary
        }
        let trendPoints = annualMetrics?.trendPoints ?? []
        if trendPoints != annualTrendPoints {
            annualTrendPoints = trendPoints
        }
    }

    /// The available-year list is independent of the active tool filter, the
    /// selected range, and the heatmap year.
    private func loadAvailableYears() async {
        let years = (try? await aggregator.fetchAvailableYears()) ?? []
        if Task.isCancelled { return }
        if years != availableYears {
            availableYears = years
        }
        if !years.isEmpty && !years.contains(selectedHeatmapYear) {
            selectedHeatmapYear = years.first!
        }
    }

    /// Today's focus is intentionally independent of the selected dashboard
    /// range. It is a quick operational summary, while the hero and charts
    /// continue to represent the active range/filter.
    private func loadTodaySummary() async {
        let summary = try? await aggregator.fetchTodaySummary()
        if Task.isCancelled { return }
        todaySummary = summary
        lastDataRefreshAt = Date()
    }

    /// Full refresh used by the throttled data-update notification path. Reuses
    /// the four dimension-scoped pipelines so there is a single code path.
    private func loadData() async {
        await loadPeriodMetrics()
        await loadRangeActiveAgents()
        await loadAnnualSummaryData()
        await loadAvailableYears()
        await loadTodaySummary()
    }

    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            let seconds = UserDefaults.standard.integer(forKey: "bennett_auto_refresh_seconds")
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { return }
                // Skip the reload while the dashboard window is hidden,
                // minimized or fully occluded: re-aggregating the range data and
                // rebuilding the 365-cell heatmap for an off-screen window is
                // wasted work that needlessly keeps the process busy.
                guard dashboardWindowIsVisible() else { continue }
                refreshTick += 1
            } else {
                // Manual mode. `bennett_auto_refresh_seconds` has no
                // `register(defaults:)` default, so an unset key reads as 0 and
                // lands here. The loop must not simply `return`: the owning
                // `.task {}` only re-runs when the view appears, so exiting would
                // ignore a later "enable auto-refresh" change until the window is
                // reopened. Poll the setting at a low frequency instead of the
                // previous 3 s spin so an idle process is no longer woken every
                // 3 s.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// Whether a visible, non-minimized, non-occluded top-level dashboard window
    /// is currently on screen. The dashboard window is the app's only regular
    /// window that is titled and not a sheet: the status item's window is
    /// untitled, the popover is a panel, and the settings sheet is attached to
    /// the dashboard window (`isSheet == true`) and therefore excluded here.
    private func dashboardWindowIsVisible() -> Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.styleMask.contains(.titled)
                && !window.isSheet
                && window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }
}

fileprivate func tooltipPosition(for loc: CGPoint, in size: CGSize, tooltipSize: CGSize) -> CGPoint {
    var posX = loc.x
    var posY = loc.y - tooltipSize.height / 2 - 14

    if posY - tooltipSize.height / 2 < 4 {
        posY = loc.y + tooltipSize.height / 2 + 14
    }

    let minX = tooltipSize.width / 2 + 8
    let maxX = size.width - tooltipSize.width / 2 - 8
    posX = min(max(posX, minX), maxX)

    return CGPoint(x: posX, y: posY)
}

/// One trend bucket with its model rows pre-sorted. Lets `TrendChartCard`
/// evaluate its O(P*M) aggregations once per body instead of re-running them
/// at every use site (legend, scales, bar/line paths, tooltip).
private struct TrendBucket: Identifiable {
    let point: TrendPoint
    let rows: [(model: String, tokens: Int)]
    var id: String { point.id }
}

private struct TrendChartCard: View {
    let trendPoints: [TrendPoint]
    let trendTitle: String
    let rangeSubtitle: String
    var modelColors: [String: Color] = [:]
    @ObservedObject var localization: LocalizationManager
    @ObservedObject var pricingEngine: PricingEngine

    @State private var trendChartType: TrendChartType = .bar
    @State private var hoveredTrendPeriod: String? = nil
    @State private var trendHoverLocation: CGPoint? = nil
    @State private var lastTrendHoverLocation: CGPoint? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(trendTitle)
                    .font(.headline)
                Spacer()
                Picker(
                    TrendChartType.accessibilityTitle(localization: localization),
                    selection: $trendChartType
                ) {
                    Image(systemName: "chart.bar.fill")
                        .help(localization.localized(.chartTypeBar))
                        .accessibilityLabel(TrendChartType.bar.accessibilityLabel(localization: localization))
                        .tag(TrendChartType.bar)
                    Image(systemName: "chart.xyaxis.line")
                        .help(localization.localized(.chartTypeLine))
                        .accessibilityLabel(TrendChartType.line.accessibilityLabel(localization: localization))
                        .tag(TrendChartType.line)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
            }

            if trendPoints.contains(where: { $0.tokens > 0 }) {
                let visibleLabels = visibleXAxisLabels(for: trendPoints)
                let hasBreakdown = hasModelBreakdown
                let modelNames = hasBreakdown ? activeModelNames() : []
                let modelRange = modelNames.map { modelColors[$0] ?? .gray }
                // Evaluated once per body: previously activeModelNames() ran up
                // to 4x per body and breakdown(for:) re-sorted every bucket at
                // each use site.
                let buckets = trendPoints.map { TrendBucket(point: $0, rows: breakdown(for: $0)) }
                Chart {
                    if hasBreakdown {
                        if trendChartType == .bar {
                            ForEach(buckets) { bucket in
                                ForEach(bucket.rows, id: \.model) { row in
                                    BarMark(
                                        x: .value("Period", bucket.point.label),
                                        y: .value("Tokens", row.tokens)
                                    )
                                    .foregroundStyle(by: .value("Model", row.model))
                                    .cornerRadius(3)
                                    .opacity(hoveredTrendPeriod == nil || hoveredTrendPeriod == bucket.point.label ? 1.0 : 0.35)
                                }
                            }
                        } else {
                            // Empty buckets must still produce a mark: a
                            // model's line has to dip to zero when it was idle,
                            // both to stay visible in ranges where it only
                            // appears once and to avoid bridging idle buckets.
                            // `by:` is what gives each model its own series —
                            // a constant `foregroundStyle` puts every model on
                            // one polyline that jumps across the whole chart.
                            ForEach(modelNames, id: \.self) { model in
                                ForEach(trendPoints) { item in
                                    LineMark(
                                        x: .value("Period", item.label),
                                        y: .value("Tokens", item.modelTokens[model] ?? 0)
                                    )
                                    .foregroundStyle(by: .value("Model", model))
                                    .interpolationMethod(.monotone)
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                            }
                            ForEach(buckets) { bucket in
                                if hoveredTrendPeriod == bucket.point.label {
                                    ForEach(bucket.rows, id: \.model) { row in
                                        PointMark(
                                            x: .value("Period", bucket.point.label),
                                            y: .value("Tokens", row.tokens)
                                        )
                                        .foregroundStyle(modelColors[row.model] ?? .gray)
                                        .symbolSize(50)
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(trendPoints) { item in
                            if trendChartType == .bar {
                                BarMark(
                                    x: .value("Period", item.label),
                                    y: .value("Tokens", item.tokens)
                                )
                                .foregroundStyle(AppTheme.Chart.primaryLine.gradient)
                                .cornerRadius(3)
                                .opacity(hoveredTrendPeriod == nil || hoveredTrendPeriod == item.label ? 1.0 : 0.35)
                            } else {
                                AreaMark(
                                    x: .value("Period", item.label),
                                    y: .value("Tokens", item.tokens)
                                )
                                .foregroundStyle(AppTheme.Chart.primaryAreaGradient)
                                .interpolationMethod(.monotone)

                                LineMark(
                                    x: .value("Period", item.label),
                                    y: .value("Tokens", item.tokens)
                                )
                                .foregroundStyle(AppTheme.Chart.primaryLine)
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2))

                                if hoveredTrendPeriod == item.label {
                                    PointMark(
                                        x: .value("Period", item.label),
                                        y: .value("Tokens", item.tokens)
                                    )
                                    .foregroundStyle(AppTheme.Chart.primaryLine)
                                    .symbolSize(50)
                                }
                            }
                        }
                    }

                    if let hovered = hoveredTrendPeriod, trendPoints.contains(where: { $0.label == hovered }) {
                        RuleMark(x: .value("Period", hovered))
                            .foregroundStyle(AppTheme.Text.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        guard let plotFrame = proxy.plotFrame else {
                                            trendHoverLocation = nil
                                            lastTrendHoverLocation = nil
                                            if hoveredTrendPeriod != nil {
                                                hoveredTrendPeriod = nil
                                            }
                                            return
                                        }
                                        let frame = geo[plotFrame]
                                        let isInside = loc.x >= frame.minX && loc.x <= frame.maxX &&
                                                       loc.y >= frame.minY && loc.y <= frame.maxY + 24
                                        let next: String? = {
                                            guard isInside else { return nil }
                                            guard let label = proxy.value(atX: loc.x - frame.origin.x, as: String.self) else { return nil }
                                            return trendPoints.contains(where: { $0.label == label }) ? label : nil
                                        }()
                                        if hoveredTrendPeriod != next {
                                            hoveredTrendPeriod = next
                                            lastTrendHoverLocation = next != nil ? loc : nil
                                            trendHoverLocation = next != nil ? loc : nil
                                        } else if next != nil, shouldUpdateTrendHoverLocation(loc) {
                                            trendHoverLocation = loc
                                            lastTrendHoverLocation = loc
                                        }
                                    case .ended:
                                        trendHoverLocation = nil
                                        lastTrendHoverLocation = nil
                                        if hoveredTrendPeriod != nil {
                                            hoveredTrendPeriod = nil
                                        }
                                    }
                                }

                            if let loc = trendHoverLocation,
                               let hovered = hoveredTrendPeriod,
                               let bucket = buckets.first(where: { $0.point.label == hovered }) {
                                let point = bucket.point
                                let rows = hasBreakdown ? Array(bucket.rows.prefix(6)) : []
                                let tooltipWidth: CGFloat = rows.isEmpty ? 150 : 200
                                let tooltipHeight: CGFloat = rows.isEmpty ? 56 : (64 + CGFloat(rows.count) * 16)
                                let tooltipSize = CGSize(width: tooltipWidth, height: tooltipHeight)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(point.label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundColor(AppTheme.Text.secondary)
                                        Spacer()
                                        Text(pricingEngine.spendString(point.costUSD))
                                            .font(.caption2.monospacedDigit().weight(.medium))
                                            .foregroundColor(AppTheme.Status.success)
                                    }

                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(TokenFormatter.formatFull(point.tokens))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundColor(AppTheme.Text.primary)
                                        Text(localization.localized(.tokenUnit))
                                            .font(.caption2)
                                            .foregroundColor(AppTheme.Text.tertiary)
                                    }

                                    if !rows.isEmpty {
                                        Divider()
                                            .overlay(AppTheme.Border.divider)

                                        VStack(spacing: 3) {
                                            ForEach(rows, id: \.model) { row in
                                                HStack(spacing: 6) {
                                                    Circle()
                                                        .fill(modelColors[row.model] ?? .gray)
                                                        .frame(width: 5, height: 5)
                                                    Text(row.model)
                                                        .font(.caption2)
                                                        .foregroundColor(AppTheme.Text.primary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                    Spacer(minLength: 8)
                                                    Text(TokenFormatter.formatCompact(row.tokens))
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundColor(AppTheme.Text.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(width: tooltipWidth)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.ultraThinMaterial)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                                .position(tooltipPosition(for: loc, in: geo.size, tooltipSize: tooltipSize))
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 230)
                // The custom legend below the chart replaces Swift Charts'
                // auto-generated one; leaving both rendered duplicated rows.
                .chartLegend(.hidden)
                .chartForegroundStyleScale(domain: modelNames, range: modelRange)
                .chartXAxis {
                    AxisMarks(values: visibleLabels) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(AppTheme.Chart.gridline)
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppTheme.Border.subtle)
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(str)
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Text.tertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(AppTheme.Chart.gridline)
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppTheme.Border.subtle)
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(TokenFormatter.formatCompact(tokens))
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Text.tertiary)
                            } else if let tokens = value.as(Double.self) {
                                Text(TokenFormatter.formatCompact(Int(tokens)))
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Text.tertiary)
                            }
                        }
                    }
                }
                if hasBreakdown {
                    if !modelNames.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(modelNames, id: \.self) { model in
                                HStack(spacing: 6) {
                                    Circle().fill(modelColors[model] ?? .gray).frame(width: 8, height: 8)
                                    Text(model)
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chart.bar")
                        .font(.system(size: 32))
                        .foregroundColor(AppTheme.Text.tertiary)
                    Text(localization.localized(.noActivityRecorded, arguments: rangeSubtitle))
                        .foregroundColor(AppTheme.Text.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(height: 230)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
}

    private func shouldUpdateTrendHoverLocation(_ loc: CGPoint) -> Bool {
        guard let last = lastTrendHoverLocation else { return true }
        let dx = loc.x - last.x
        let dy = loc.y - last.y
        return dx * dx + dy * dy > 4
    }
    private func visibleXAxisLabels(for points: [TrendPoint]) -> [String] {
        let count = points.count
        guard count > 0 else { return [] }
        let step = max(1, Int(ceil(Double(count) / 8)))
        var visible = stride(from: 0, to: count, by: step).map { points[$0].label }
        if let last = points.last, !visible.contains(last.label) {
            visible.append(last.label)
        }
        return visible
    }

    private var hasModelBreakdown: Bool {
        trendPoints.contains { !$0.modelTokens.isEmpty }
    }

    /// Models with tokens > 0 for a single bucket, sorted by tokens descending.
    private func breakdown(for point: TrendPoint) -> [(model: String, tokens: Int)] {
        point.modelTokens
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// Models with tokens > 0 across the whole interval, sorted by total tokens descending.
    private func activeModelNames() -> [String] {
        var totals: [String: Int] = [:]
        for point in trendPoints {
            for (model, tokens) in point.modelTokens where tokens > 0 {
                totals[model, default: 0] += tokens
            }
        }
        return totals
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
    }
}

/// Proportional segmented bar card for tool or model usage distribution.
/// Replaces legacy heavy donut charts with sleek continuous horizontal capsules and clean contributor rows.
struct ProportionalDistributionCard: View {
    typealias Item = (id: String, name: String, tokens: Int, costUSD: Double, color: Color)

    let title: String
    let subtitle: String
    let items: [(id: String, name: String, tokens: Int, costUSD: Double, color: Color)]
    let totalTokens: Int
    @ObservedObject var localization: LocalizationManager
    @ObservedObject var pricingEngine: PricingEngine
    var emptyMessage: String? = nil
    var emptyIcon: String = "chart.bar.xaxis"

    init(
        title: String,
        subtitle: String,
        items: [(id: String, name: String, tokens: Int, costUSD: Double, color: Color)],
        totalTokens: Int,
        localization: LocalizationManager,
        emptyMessage: String? = nil,
        emptyIcon: String = "chart.bar.xaxis",
        pricingEngine: PricingEngine = .shared
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.totalTokens = totalTokens
        self.localization = localization
        self.pricingEngine = pricingEngine
        self.emptyMessage = emptyMessage
        self.emptyIcon = emptyIcon
    }

    private var activeItems: [Item] {
        items.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
    }

    private var topContributors: [Item] {
        Array(activeItems.prefix(4))
    }

    private var resolvedEmptyMessage: String {
        if let emptyMessage = emptyMessage {
            return emptyMessage
        }
        if !subtitle.isEmpty {
            return localization.localized(.noActivityRecorded, arguments: subtitle)
        }
        return localization.localized(.noTokenUsage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title + Range Subtitle
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(AppTheme.Text.primary)
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                }
            }

            if totalTokens > 0 && !activeItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // 10pt continuous horizontal segmented bar
                    GeometryReader { geo in
                        let totalWidth = geo.size.width
                        let effectiveTotal = max(totalTokens, activeItems.reduce(0) { $0 + $1.tokens })
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.Surface.subtle)

                            HStack(spacing: 0) {
                                ForEach(activeItems, id: \.id) { item in
                                    let ratio = CGFloat(item.tokens) / CGFloat(effectiveTotal)
                                    let pct = Double(item.tokens) / Double(effectiveTotal) * 100
                                    Rectangle()
                                        .fill(item.color)
                                        .frame(width: max(ratio * totalWidth, 0))
                                        .help("\(item.name): \(TokenFormatter.formatCompact(item.tokens)) (\(String(format: "%.1f%%", pct)))")
                                }
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .frame(height: 10)

                    // Contributor list: Top 4 items
                    VStack(spacing: 8) {
                        ForEach(topContributors, id: \.id) { item in
                            let effectiveTotal = max(totalTokens, activeItems.reduce(0) { $0 + $1.tokens })
                            let pct = effectiveTotal > 0 ? (Double(item.tokens) / Double(effectiveTotal) * 100) : 0
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 6, height: 6)

                                Text(item.name)
                                    .font(.subheadline)
                                    .foregroundColor(AppTheme.Text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text(String(format: "%.1f%%", pct))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundColor(AppTheme.Text.tertiary)

                                Spacer(minLength: 8)

                                HStack(spacing: 4) {
                                    Text(TokenFormatter.formatCompact(item.tokens))
                                        .font(.subheadline)
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.Text.secondary)
                                    Text("·")
                                        .font(.caption)
                                        .foregroundColor(AppTheme.Text.tertiary)
                                    Text(pricingEngine.spendString(item.costUSD))
                                        .font(.subheadline)
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.Text.secondary)
                                }
                            }
                            .help("\(item.name)\n\(TokenFormatter.formatFull(item.tokens)) tokens · \(pricingEngine.spendString(item.costUSD))")
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: emptyIcon)
                        .font(.system(size: 28))
                        .foregroundColor(AppTheme.Text.tertiary.opacity(0.6))
                    Text(resolvedEmptyMessage)
                        .font(.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
    }
}

private struct AnnualMonthlyTrendCard: View {
    let annualTrendPoints: [TrendPoint]
    let selectedHeatmapYear: Int
    @ObservedObject var localization: LocalizationManager
    @ObservedObject var pricingEngine: PricingEngine

    @State private var hoveredAnnualMonth: String? = nil
    @State private var annualMonthHoverLocation: CGPoint? = nil
    @State private var lastAnnualHoverLocation: CGPoint? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if annualTrendPoints.contains(where: { $0.tokens > 0 }) {
                Chart {
                    ForEach(annualTrendPoints) { item in
                        BarMark(
                            x: .value("Month", item.label),
                            y: .value("Tokens", item.tokens)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(4)
                        .opacity(hoveredAnnualMonth == nil || hoveredAnnualMonth == item.label ? 1.0 : 0.4)
                    }

                    if let hovered = hoveredAnnualMonth, annualTrendPoints.contains(where: { $0.label == hovered }) {
                        RuleMark(x: .value("Month", hovered))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        guard let plotFrame = proxy.plotFrame else {
                                            annualMonthHoverLocation = nil
                                            lastAnnualHoverLocation = nil
                                            hoveredAnnualMonth = nil
                                            return
                                        }
                                        let frame = geo[plotFrame]
                                        let isInside = loc.x >= frame.minX && loc.x <= frame.maxX &&
                                                       loc.y >= frame.minY && loc.y <= frame.maxY + 24
                                        let next: String? = {
                                            guard isInside else { return nil }
                                            guard let label = proxy.value(atX: loc.x - frame.origin.x, as: String.self) else { return nil }
                                            return annualTrendPoints.contains(where: { $0.label == label }) ? label : nil
                                        }()
                                        if hoveredAnnualMonth != next {
                                            hoveredAnnualMonth = next
                                            lastAnnualHoverLocation = next != nil ? loc : nil
                                            annualMonthHoverLocation = next != nil ? loc : nil
                                        } else if next != nil, shouldUpdateAnnualHoverLocation(loc) {
                                            annualMonthHoverLocation = loc
                                            lastAnnualHoverLocation = loc
                                        }
                                    case .ended:
                                        annualMonthHoverLocation = nil
                                        lastAnnualHoverLocation = nil
                                        hoveredAnnualMonth = nil
                                    }
                                }

                            if let loc = annualMonthHoverLocation,
                               let hovered = hoveredAnnualMonth,
                               let point = annualTrendPoints.first(where: { $0.label == hovered }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.label)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(TokenFormatter.formatFull(point.tokens)) tokens")
                                        .font(.caption).bold()
                                    Text(pricingEngine.spendString(point.costUSD))
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.Status.success)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .shadow(color: Color.black.opacity(0.2), radius: 3, x: 0, y: 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.8)
                                )
                                .position(tooltipPosition(for: loc, in: geo.size, tooltipSize: CGSize(width: 140, height: 60)))
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisTick()
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(str)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisTick()
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(TokenFormatter.formatCompact(tokens))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else if let tokens = value.as(Double.self) {
                                Text(TokenFormatter.formatCompact(Int(tokens)))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(localization.localized(.noActivityRecorded, arguments: String(selectedHeatmapYear)))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
            }
        }
}

    private func shouldUpdateAnnualHoverLocation(_ loc: CGPoint) -> Bool {
        guard let last = lastAnnualHoverLocation else { return true }
        let dx = loc.x - last.x
        let dy = loc.y - last.y
        return dx * dx + dy * dy > 4
    }
}

#Preview {
    let db = try! DatabaseManager.inMemory()
    let aggregator = MetricsAggregator(database: db)
    return DashboardContentView(aggregator: aggregator)
        .frame(width: 900, height: 700)
}
