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
    private var projectRankings: [(project: String, totalTokens: Int, costUSD: Double)] {
        Array((periodMetrics?.projectRankings ?? []).prefix(MetricsAggregator.projectRankingLimit))
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Layout.sectionSpacing) {
                // The header and the global controls form one band separated by a
                // hairline, not two independently bordered cards. The time range
                // and agent filter therefore stay in a fixed, predictable place
                // and do not compete with the conclusion below them.
                contextHeaderSection
                filterControlsSection
                conclusionPanel
                trendAndSourceSection
                todayFocusSection
                projectsSection
                heatmapSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Layout.canvasPadding)
            .padding(.top, AppTheme.Layout.compactSpacing)
            .padding(.bottom, AppTheme.Layout.canvasPadding)
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

    // MARK: - Dashboard Context Header

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

    /// A segmented control with a single accent. The selected segment is the
    /// one filled element in the strip, so "which range am I looking at" is
    /// answered by fill rather than by a shadow and a weight change.
    private func rangePill(_ option: TimeRangeOption, title: String) -> some View {
        let isSelected = selectedRange == option
        return Button {
            selectedRange = option
        } label: {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? Color.white : AppTheme.Text.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? AppTheme.Chrome.accentFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    private var contextHeaderSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.dashboardContext))
                    .font(AppTheme.Typography.pageTitle)
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(localization.localized(.dashboardContextDescription))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 12)

            freshnessBadge

            if let onOpenSettings = onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSettingsHovered ? AppTheme.Text.primary : AppTheme.Text.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSettingsHovered ? AppTheme.Surface.hover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isSettingsHovered = $0 }
                .help(localization.localized(.settings))
                .accessibilityLabel(localization.localized(.settings))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Freshness is a state, so it is the one place in the header allowed to
    /// use a status color — and it only turns green when the data really is
    /// fresh. A stale or failed sync is a different hue, not a gray pill.
    private var freshnessBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: freshnessIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(freshnessColor)
            Text(dataFreshnessText)
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .help(localization.localized(.syncFreshness) + " · " + dataFreshnessText)
        .accessibilityElement(children: .combine)
    }

    private var freshnessColor: Color {
        guard let lastDataRefreshAt else { return AppTheme.Text.tertiary }
        let minutes = Int(Date().timeIntervalSince(lastDataRefreshAt) / 60)
        return minutes < 60 ? AppTheme.Status.success : AppTheme.Status.warning
    }

    private var freshnessIcon: String {
        guard let lastDataRefreshAt else { return "circle.dashed" }
        let minutes = Int(Date().timeIntervalSince(lastDataRefreshAt) / 60)
        return minutes < 60 ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
    }

    // MARK: - Range & Agent Controls

    /// The global controls sit on the canvas rather than inside a card. A
    /// bordered container here used to leave most of its width empty and made
    /// the toolbar look like a peer of the data below it; as a bare strip it
    /// reads as chrome, and the hairline under it fixes its position on screen.
    private var filterControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    responsiveRangePicker
                    annualRangeBadge
                    Spacer(minLength: 8)
                    selectedAgentSummary
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        responsiveRangePicker
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        annualRangeBadge
                        Spacer(minLength: 0)
                        selectedAgentSummary
                    }
                }
            }

            AgentFilterBarView(
                selectedAgent: selectedToolFilter,
                availableAgents: agentNames,
                localization: localization
            ) { agent in
                selectedToolFilter = agent
                selectedCell = nil
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            AppTheme.Border.divider.frame(height: AppTheme.Layout.hairline)
        }
    }

    private var rangeControlLabel: some View {
        Text(localization.localized(.range))
            .font(.caption.weight(.semibold))
            .foregroundColor(AppTheme.Text.secondary)
            .fixedSize()
    }

    @ViewBuilder
    private var annualRangeBadge: some View {        if case .year(let year) = selectedRange {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10, weight: .medium))
                Text(localization.localized(.viewingAnnualDashboard, arguments: String(year)))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Button {
                    selectedRange = .last30Days
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(localization.localized(.exitAnnualDashboard))
            }
            .foregroundColor(AppTheme.Status.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppTheme.Surface.selected)
            )
        }
    }

    @ViewBuilder
    private var selectedAgentSummary: some View {
        if let selectedToolFilter {
            HStack(spacing: 5) {
                Circle()
                    .fill(AgentFilterBarView.colorMap[selectedToolFilter] ?? AppTheme.Status.accent)
                    .frame(width: 6, height: 6)
                Text(AgentFilterBarView.displayName(for: selectedToolFilter))
                    .font(.caption.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)
            }
            .help(localization.localized(.selectedRange, arguments: AgentFilterBarView.displayName(for: selectedToolFilter)))
        }
    }

    // MARK: - Status Summary, Highlights & Exploration

    /// One continuous panel that answers "how much, at what cost, and from
    /// where" before any chart is drawn.
    ///
    /// The previous layout split this across two identically styled cards and
    /// repeated the active range inside each one, so the first screen showed
    /// "24 hours" four times and no clear primary reading. Here the total owns
    /// the left third, the cost and cache figures sit beside it, and the three
    /// top contributors share one row underneath, all inside a single surface.
    private var conclusionPanel: some View {
        let topAgent = toolDistribution
            .filter { $0.tokens > 0 }
            .max { $0.tokens < $1.tokens }
        let topModel = (periodMetrics?.modelDistribution ?? [])
            .filter { $0.tokens > 0 }
            .max { $0.tokens < $1.tokens }
        let topProject = projectRankings.first
        let hasHighlights = topAgent != nil || topModel != nil || topProject != nil

        return ContinuousPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                conclusionHeadline
                PanelDivider(inset: 0)
                if hasHighlights {
                    conclusionContributors(
                        topAgent: topAgent,
                        topModel: topModel,
                        topProject: topProject
                    )
                } else {
                    conclusionEmptyState
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The headline row: total tokens, then the two derived figures. Spend is
    /// deliberately *not* green — money is a value, not a health state, and
    /// coloring it as success made a $0.18 reading look like a status light.
    private var conclusionHeadline: some View {
        let totalTokens = periodMetrics?.totalTokens ?? 0
        let scopeTitle = selectedToolFilter.map { AgentFilterBarView.displayName(for: $0) }
            ?? localization.localized(.allAgentsUsage)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                conclusionTotal(scopeTitle: scopeTitle, totalTokens: totalTokens)
                Rectangle()
                    .fill(AppTheme.Border.divider)
                    .frame(width: AppTheme.Layout.hairline, height: 54)
                conclusionSecondaryMetrics
            }
            VStack(alignment: .leading, spacing: 18) {
                conclusionTotal(scopeTitle: scopeTitle, totalTokens: totalTokens)
                conclusionSecondaryMetrics
            }
        }
        .padding(.horizontal, AppTheme.Layout.cellPadding + 2)
        .padding(.vertical, 18)
    }

    private func conclusionTotal(scopeTitle: String, totalTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(localization.localized(.periodTokens))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(TokenFormatter.formatCompact(totalTokens))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                Text(localization.localized(.tokenUnit))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.Text.tertiary)
            }
            Text(scopeTitle)
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
            Text("\(localization.localized(.exactValue)) \(TokenFormatter.formatFull(totalTokens))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(AppTheme.Text.quaternary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("\(TokenFormatter.formatFull(totalTokens)) \(localization.localized(.tokenUnit))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(localization.localized(.periodTokens)), \(scopeTitle), \(TokenFormatter.formatFull(totalTokens)) \(localization.localized(.tokenUnit))")
    }

    private var conclusionSecondaryMetrics: some View {
        // Fixed widths rather than `maxWidth: .infinity`: an infinitely
        // flexible pair of metrics drifts to opposite ends of the remaining
        // row and opens a gap in the middle of the headline.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 40) {
                conclusionSpendMetric.frame(width: 132, alignment: .leading)
                conclusionCacheMetric.frame(width: 208, alignment: .leading)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 14) {
                conclusionSpendMetric
                conclusionCacheMetric
            }
        }
    }

    private var conclusionSpendMetric: some View {
        MetricCell(
            label: localization.localized(.periodSpend),
            value: pricingEngine.spendString(periodMetrics?.totalCostUSD ?? 0)
        )
    }

    private var conclusionCacheMetric: some View {
        let rate = periodMetrics?.cacheHitRate ?? 0
        return MetricCell(
            label: localization.localized(.cacheHitRate),
            value: String(format: "%.1f%%", rate * 100)
        ) {
            PercentageMeter(value: rate, color: AppTheme.Data.series)
        }
    }

    /// The three "why" answers on one row. Each is a plain metric cell: the
    /// agent's categorical hue appears only as a 6pt identity dot, never as a
    /// heading icon, so the colors on this row keep their meaning elsewhere.
    private func conclusionContributors(
        topAgent: (tool: String, tokens: Int, costUSD: Double)?,
        topModel: (model: String, tokens: Int, costUSD: Double)?,
        topProject: (project: String, totalTokens: Int, costUSD: Double)?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                if let topAgent {
                    contributorCell(
                        label: localization.localized(.topAgent),
                        value: AgentFilterBarView.displayName(for: topAgent.tool),
                        detail: TokenFormatter.formatCompact(topAgent.tokens),
                        dotColor: cachedAgentColors[topAgent.tool.lowercased()]
                    )
                }
                if let topModel {
                    contributorCell(
                        label: localization.localized(.modelDistribution),
                        value: topModel.model,
                        detail: TokenFormatter.formatCompact(topModel.tokens),
                        dotColor: cachedModelColors[topModel.model]
                    )
                }
                if let topProject {
                    contributorCell(
                        label: localization.localized(.topProjectsDrillDown),
                        value: projectDisplayName(topProject.project),
                        detail: TokenFormatter.formatCompact(topProject.totalTokens),
                        dotColor: nil
                    )
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                if let topAgent {
                    contributorCell(
                        label: localization.localized(.topAgent),
                        value: AgentFilterBarView.displayName(for: topAgent.tool),
                        detail: TokenFormatter.formatCompact(topAgent.tokens),
                        dotColor: cachedAgentColors[topAgent.tool.lowercased()]
                    )
                }
                if let topModel {
                    contributorCell(
                        label: localization.localized(.modelDistribution),
                        value: topModel.model,
                        detail: TokenFormatter.formatCompact(topModel.tokens),
                        dotColor: cachedModelColors[topModel.model]
                    )
                }
                if let topProject {
                    contributorCell(
                        label: localization.localized(.topProjectsDrillDown),
                        value: projectDisplayName(topProject.project),
                        detail: TokenFormatter.formatCompact(topProject.totalTokens),
                        dotColor: nil
                    )
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.cellPadding + 2)
        .padding(.vertical, 14)
    }

    private func contributorCell(
        label: String,
        value: String,
        detail: String,
        dotColor: Color?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // The dot slot is reserved even for the project cell so the
                // three labels share one left edge; a label that starts 11pt
                // further left than its neighbours reads as misaligned.
                Group {
                    if let dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    } else {
                        Color.clear.frame(width: 6, height: 6)
                    }
                }
                Text(label)
                    .font(AppTheme.Typography.label)
                    .foregroundColor(AppTheme.Text.tertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(AppTheme.Typography.rowTitle)
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(AppTheme.Typography.caption.monospacedDigit())
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
        .accessibilityElement(children: .combine)
    }

    private var conclusionEmptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.quaternary)
            Text(localization.localized(.noActivityRecorded, arguments: rangeSubtitle))
                .font(.subheadline)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Layout.cellPadding + 2)
        .padding(.vertical, 16)
    }


    /// The trend owns its own full-width band, and the two distribution
    /// summaries share the row beneath it.
    ///
    /// Pairing a ~450pt chart with a ~200pt agent card left a column of dead
    /// canvas that read as a layout mistake. Giving the chart the full width
    /// also matches the priority order the spec asks for: when usage changed
    /// comes first, who spent it comes second — not side by side at equal
    /// weight.
    private var trendAndSourceSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Layout.sectionSpacing) {
            trendChartCard

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppTheme.Layout.sectionSpacing) {
                    tokenCompositionSection.frame(maxWidth: .infinity)
                    agentUsageSection.frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionSpacing) {
                    tokenCompositionSection
                    agentUsageSection
                }
            }
        }
    }

    private var trendChartCard: some View {
        TrendChartCard(
            trendPoints: periodMetrics?.trendPoints ?? [],
            trendTitle: trendTitle,
            rangeSubtitle: rangeSubtitle,
            modelColors: cachedModelColors,
            localization: localization,
            pricingEngine: pricingEngine
        )
    }

    private func projectDisplayName(_ project: String) -> String {
        let displayName = (project as NSString).lastPathComponent
        return displayName.isEmpty ? project : displayName
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
                color: AppTheme.Chrome.glyph
            )
            Divider().frame(height: 24).opacity(0.3).padding(.horizontal, 8)

            // 2. Annual Cost
            annualStatItem(
                title: localization.localized(.annualSpend),
                value: pricingEngine.spendString(summary.annualCostUSD),
                subvalue: summary.annualCostUSD > 0 ? (pricingEngine.preferredCurrency == .cny ? "CNY" : "USD") : "-",
                icon: "dollarsign.circle.fill",
                color: AppTheme.Chrome.glyph
            )
            Divider().frame(height: 24).opacity(0.3).padding(.horizontal, 8)

            // 3. Active Days
            let pct = summary.totalDays > 0 ? (Double(summary.activeDays) / Double(summary.totalDays) * 100.0) : 0.0
            annualStatItem(
                title: localization.localized(.annualActiveDays),
                value: "\(summary.activeDays) / \(summary.totalDays)",
                subvalue: String(format: "%.1f%%", pct),
                icon: "calendar.badge.checkmark",
                color: AppTheme.Chrome.glyph
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
                color: AppTheme.Chrome.glyph,
                dotColor: summary.mostActiveTool != "None" ? agentColor : nil
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Surface.subtle)
        )
    }

    private func annualStatItem(
        title: String,
        value: String,
        subvalue: String,
        icon: String,
        color: Color,
        dotColor: Color? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 16)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
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

    /// Shown only when the active range is *not* already today.
    ///
    /// This band used to render unconditionally, directly beneath the
    /// conclusion panel, repeating the same three readings a few pixels apart
    /// — selecting "24 hours" put 3.28B / $0.18 / Pi Agent on screen and then
    /// 3.29B / $0.17 / Pi Agent a card below it. On the "today" range it was a
    /// pure duplicate; on every other range it was a distraction that competed
    /// with the exploration sections it was meant to summarize.
    @ViewBuilder
    private var todayFocusSection: some View {
        if selectedRange != .today {
            todayFocusContent
        }
    }

    private var todayFocusContent: some View {
        let summary = todaySummary
        let activeTools = MenuBarPopoverView.activeTools(for: summary)
        let topAgent = activeTools.first
        let totalTokens = summary?.totalTokens ?? 0
        let totalCost = summary?.totalCostUSD ?? 0.0

        // A quiet inset, not a second white panel. As a peer of the conclusion
        // panel this band rhymed with it — three large figures in a row, the
        // same three subjects, a card apart — and the reader could not tell
        // which one was the answer to "how much".
        return ContinuousPanel(background: AppTheme.Surface.subtle.opacity(0.55)) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(localization.localized(.todayFocus)) {
                    if let topAgent {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(cachedAgentColors[topAgent.id] ?? AppTheme.Text.tertiary)
                                .frame(width: 6, height: 6)
                            Text(localization.localized(.popoverTopAgent, arguments: AgentFilterBarView.displayName(for: topAgent.id)))
                                .font(AppTheme.Typography.caption)
                                .foregroundColor(AppTheme.Text.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 0) {
                        MetricCell(
                            label: localization.localized(.periodTokens),
                            value: TokenFormatter.formatCompact(totalTokens),
                            detail: TokenFormatter.formatFull(totalTokens),
                            valueFont: AppTheme.Typography.contextTitle
                        )
                        focusDivider
                        MetricCell(
                            label: localization.localized(.estimatedCost),
                            value: pricingEngine.spendString(totalCost),
                            valueFont: AppTheme.Typography.contextTitle
                        )
                        focusDivider
                        MetricCell(
                            label: localization.localized(.mostActiveAgent),
                            value: topAgent.map { AgentFilterBarView.displayName(for: $0.id) } ?? localization.localized(.none),
                            detail: topAgent.map { TokenFormatter.formatCompact($0.tokens) },
                            valueFont: AppTheme.Typography.contextTitle
                        )
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        MetricCell(
                            label: localization.localized(.periodTokens),
                            value: TokenFormatter.formatCompact(totalTokens),
                            detail: TokenFormatter.formatFull(totalTokens)
                        )
                        MetricCell(
                            label: localization.localized(.estimatedCost),
                            value: pricingEngine.spendString(totalCost)
                        )
                        MetricCell(
                            label: localization.localized(.mostActiveAgent),
                            value: topAgent.map { AgentFilterBarView.displayName(for: $0.id) } ?? localization.localized(.none),
                            detail: topAgent.map { TokenFormatter.formatCompact($0.tokens) }
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.localized(.todayFocus))
    }

    private var focusDivider: some View {
        AppTheme.Border.divider
            .frame(width: AppTheme.Layout.hairline, height: 40)
            .padding(.horizontal, 16)
    }

    // MARK: - Token Composition & Agent Usage

    /// Uses the four first-class PeriodMetrics counters directly. In particular,
    /// it never substitutes `modelDistribution`, which is a top-10 snapshot and
    /// therefore cannot represent total token composition.
    ///
    /// The four bands are *categories*, not states, so they are drawn from the
    /// data ramp rather than from `Status`. Reusing the success/warning hues
    /// here made "cache hit" green mean both "a good state" and "a kind of
    /// token", and a user could not tell which reading they were seeing.
    private var tokenCompositionSection: some View {
        let input = periodMetrics?.inputTokens ?? 0
        let output = periodMetrics?.outputTokens ?? 0
        let cacheRead = periodMetrics?.cacheReadTokens ?? 0
        let cacheWrite = periodMetrics?.cacheWriteTokens ?? 0
        let metrics: [(id: String, label: String, tokens: Int, color: Color)] = [
            ("input", localization.localized(.inputLabel), input, AppTheme.Data.series),
            ("output", localization.localized(.outputLabel), output, AppTheme.Harmonic.palette[10]),
            ("cacheRead", localization.localized(.cacheRead), cacheRead, AppTheme.Harmonic.palette[5]),
            ("cacheWrite", localization.localized(.cacheWrite), cacheWrite, AppTheme.Harmonic.palette[2])
        ]
        let total = max(0, input + output + cacheRead + cacheWrite)

        return ContinuousPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(localization.localized(.tokenComposition))

                if total > 0 {
                    ProportionBar(
                        segments: metrics.filter { $0.tokens > 0 }.map {
                            ProportionBar.Segment(
                                id: $0.id,
                                share: Double($0.tokens),
                                color: $0.color
                            )
                        },
                        height: 8
                    )
                    .help(localization.localized(.rangeTokens, arguments: TokenFormatter.formatFull(total)))
                    .accessibilityLabel(localization.localized(.rangeTokens, arguments: TokenFormatter.formatFull(total)))

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                                if index > 0 { compositionDivider }
                                compositionMetric(metric)
                            }
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(metrics, id: \.id) { metric in
                                compositionMetric(metric)
                            }
                        }
                    }
                } else {
                    emptySection(
                        symbol: "chart.pie",
                        title: localization.localized(.noTokenUsage, arguments: rangeSubtitle)
                    )
                }
            }
        }
    }

    private func compositionMetric(_ metric: (id: String, label: String, tokens: Int, color: Color)) -> some View {
        let total = (periodMetrics?.inputTokens ?? 0)
            + (periodMetrics?.outputTokens ?? 0)
            + (periodMetrics?.cacheReadTokens ?? 0)
            + (periodMetrics?.cacheWriteTokens ?? 0)
        let share = total > 0 ? Double(metric.tokens) / Double(total) * 100 : 0

        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(metric.color)
                .frame(width: 7, height: 7)
            Text(metric.label)
                .font(AppTheme.Typography.rowDetail)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(String(format: "%.1f%%", share))
                .font(AppTheme.Typography.tabular)
                .foregroundColor(AppTheme.Text.quaternary)
            Text(TokenFormatter.formatCompact(metric.tokens))
                .font(AppTheme.Typography.rowTitle.monospacedDigit())
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(metric.label): \(TokenFormatter.formatFull(metric.tokens)) \(localization.localized(.tokenUnit))")
        .accessibilityElement(children: .combine)
    }

    private var compositionDivider: some View {
        AppTheme.Border.divider
            .frame(width: AppTheme.Layout.hairline, height: 42)
            .padding(.horizontal, 16)
    }

    private var agentUsageSection: some View {
        let toolItems: [ProportionalDistributionCard.Item] = toolDistribution.filter { $0.tokens > 0 }.map { item in
            (
                id: item.tool,
                name: AgentFilterBarView.displayName(for: item.tool),
                tokens: item.tokens,
                costUSD: item.costUSD,
                color: cachedAgentColors[item.tool.lowercased()] ?? AppTheme.Harmonic.color(for: item.tool)
            )
        }

        return ProportionalDistributionCard(
            title: localization.localized(.agentUsage),
            subtitle: localization.localized(.selectedRange, arguments: rangeSubtitle),
            items: toolItems,
            totalTokens: toolItems.reduce(0) { $0 + $1.tokens },
            localization: localization,
            emptyMessage: localization.localized(.noToolData, arguments: rangeSubtitle),
            emptyIcon: "person.2",
            pricingEngine: pricingEngine
        )
    }

    private var dataFreshnessText: String {
        guard let lastDataRefreshAt else {
            return localization.localized(.notSyncedYet)
        }
        let minutes = max(0, Int(Date().timeIntervalSince(lastDataRefreshAt) / 60))
        if minutes == 0 {
            return localization.localized(.dataUpdatedJustNow)
        }
        return localization.localized(.dataUpdatedMinutesAgo, arguments: minutes)
    }

    /// A section title. The active range is deliberately *not* repeated in the
    /// subtitle: it is already stated in the control strip directly above and
    /// restating it on every card is what made the old layout feel repetitive.
    private func sectionHeader(title: String, subtitle: String? = nil, symbol: String) -> some View {
        SectionEyebrow(title) {
            if let subtitle {
                Text(subtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.quaternary)
                    .lineLimit(1)
            }
        }
    }

    private func emptySection(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundColor(AppTheme.Text.quaternary)
            Text(title)
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Text.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - Top Projects

    private var projectsSection: some View {
        ContinuousPanel {
            VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(localization.localized(.topProjectsDrillDown)) {
                Text(localization.localized(.trackedProjectsCount, arguments: projectRankings.count))
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.quaternary)
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
                                        Capsule().fill(AppTheme.Data.track)
                                        Capsule().fill(AppTheme.Data.series)
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
                        .padding(.vertical, 5)
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
        }
    }

    // MARK: - Helpers

    /// A plain rank numeral.
    ///
    /// It used to be gold / silver / bronze by position. That is the
    /// gamification the brand spec rules out, and those three warm hues sit
    /// uncomfortably close to the agent palette — a gold "01" next to an amber
    /// agent dot read as a relationship that does not exist. Rank is already
    /// carried by row order; the numeral only has to be legible.
    private func medalBadge(rank: Int) -> some View {
        Text(String(format: "%02d", rank))
            .font(AppTheme.Typography.tabular)
            .foregroundColor(AppTheme.Text.quaternary)
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
        ContinuousPanel {
            VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(trendTitle) {
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
                .scaleEffect(0.82, anchor: .trailing)
                .frame(width: 68)
            }

            // A bare chart asks the reader to do the arithmetic. Naming the peak
            // and the mean turns the plot into a sentence the header can finish.
            trendSummaryStrip

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
                .frame(height: 300)
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
                .frame(height: 300)
                .frame(maxWidth: .infinity)
            }
            }
        }
    }

    /// Peak, mean and active-bucket count. These are the three questions a
    /// reader has about a trend line, and answering them above the plot means
    /// the chart is supporting a conclusion rather than replacing one.
    @ViewBuilder
    private var trendSummaryStrip: some View {
        let active = trendPoints.filter { $0.tokens > 0 }
        if !active.isEmpty {
            let peak = active.max { $0.tokens < $1.tokens }
            let mean = active.reduce(0) { $0 + $1.tokens } / active.count
            HStack(spacing: 20) {
                trendSummaryItem(
                    title: localization.localized(.peakUsage),
                    value: TokenFormatter.formatCompact(peak?.tokens ?? 0),
                    detail: peak?.label
                )
                trendSummaryItem(
                    title: localization.localized(.averageUsage),
                    value: TokenFormatter.formatCompact(mean),
                    detail: nil
                )
                trendSummaryItem(
                    title: localization.localized(.activeBuckets),
                    value: "\(active.count)/\(trendPoints.count)",
                    detail: nil
                )
                Spacer(minLength: 0)
            }
        }
    }

    private func trendSummaryItem(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(AppTheme.Typography.label)
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(AppTheme.Typography.rowTitle.monospacedDigit())
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Text.quaternary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
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
        // The card sits beside a tall trend chart. Showing four rows left the
        // rest of that column empty, so the list runs long enough to hold the
        // column and the eye lands on a complete ranking rather than a stub.
        Array(activeItems.prefix(7))
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
        ContinuousPanel {
            VStack(alignment: .leading, spacing: 12) {
                SectionEyebrow(title)

                if totalTokens > 0 && !activeItems.isEmpty {
                    let effectiveTotal = max(totalTokens, activeItems.reduce(0) { $0 + $1.tokens })

                    // The bar is a locator, not the subject: it is short, sits on
                    // a neutral track, and only marks proportion. The list below
                    // carries the actual readings. A full-bleed saturated bar
                    // made whichever agent happened to be largest the loudest
                    // object on the entire screen.
                    ProportionBar(
                        segments: activeItems.map {
                            ProportionBar.Segment(
                                id: $0.id,
                                share: effectiveTotal > 0 ? Double($0.tokens) / Double(effectiveTotal) : 0,
                                color: $0.color
                            )
                        },
                        height: 8
                    )

                    VStack(spacing: 0) {
                        ForEach(Array(topContributors.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                PanelDivider(inset: 18)
                            }
                            contributorRow(item, effectiveTotal: effectiveTotal)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: emptyIcon)
                            .font(.system(size: 20))
                            .foregroundColor(AppTheme.Text.quaternary)
                        Text(resolvedEmptyMessage)
                            .font(AppTheme.Typography.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                }
            }
        }
    }

    /// One row per contributor. The share is shown once, as a small type-ahead
    /// percentage; repeating "share of total" as a second line per row made the
    /// card read as noise.
    private func contributorRow(_ item: Item, effectiveTotal: Int) -> some View {
        let pct = effectiveTotal > 0 ? Double(item.tokens) / Double(effectiveTotal) * 100 : 0
        return HStack(spacing: 8) {
            Circle()
                .fill(item.color)
                .frame(width: 7, height: 7)

            Text(item.name)
                .font(AppTheme.Typography.rowTitle)
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(TokenFormatter.formatCompact(item.tokens))
                .font(AppTheme.Typography.tabular)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)

            Text(pricingEngine.spendString(item.costUSD))
                .font(AppTheme.Typography.tabular)
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
                .frame(minWidth: 48, alignment: .trailing)

            Text(String(format: "%.1f%%", pct))
                .font(AppTheme.Typography.tabular)
                .foregroundColor(AppTheme.Text.quaternary)
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .frame(height: 30)
        .help("\(item.name)\n\(TokenFormatter.formatFull(item.tokens)) tokens · \(pricingEngine.spendString(item.costUSD))")
        .accessibilityElement(children: .combine)
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
