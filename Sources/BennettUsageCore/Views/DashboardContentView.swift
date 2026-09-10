import SwiftUI
import Charts

public struct DashboardContentView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager

    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var todaySummary: TodaySummary?
    @State private var periodMetrics: PeriodMetrics?
    @State private var selectedRange: TimeRangeOption = .last30Days
    @State private var availableYears: [Int] = []
    @State private var selectedCell: HeatmapDayCell?
    @State private var selectedToolFilter: String?

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared
    ) {
        self.aggregator = aggregator
        self.localization = localization
    }

    // MARK: - Computed Helpers

    private var rangeSubtitle: String {
        switch selectedRange {
        case .last24Hours: return localization.localized(.range24h)
        case .today: return localization.localized(.rangeToday)
        case .last7Days: return localization.localized(.range7Days)
        case .last30Days: return localization.localized(.range30Days)
        case .pastYear: return localization.localized(.range1Year)
        case .year(let y): return String(y)
        }
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
        if case .year(let y) = selectedRange {
            return localization.localized(.yearTitle, arguments: String(y))
        }
        return localization.localized(.rolling365Days)
    }

    private var toolDistribution: [(tool: String, tokens: Int, costUSD: Double)] {
        periodMetrics?.toolDistribution ?? []
    }

    private var projectRankings: [(project: String, totalTokens: Int, costUSD: Double)] {
        periodMetrics?.projectRankings ?? []
    }

    private var availableAgents: [String] {
        let fromDistribution = toolDistribution.map(\.tool)
        let fromHeatmap = Set(heatmapCells.flatMap { $0.toolBreakdown.keys })
        let all = Set(fromDistribution).union(fromHeatmap)
        return all.sorted()
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                agentFilterSection
                kpiSection
                heatmapSection
                chartsSection
                projectsSection
            }
            .padding(24)
        }
        .task(id: "\(selectedRange)_\(selectedToolFilter ?? "all")") {
            await loadData()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.localized(.dashboardTitle))
                    .font(.title2).bold()
                Text(localization.localized(.dashboardSubtitle))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Picker(localization.localized(.range), selection: $selectedRange) {
                    Text(localization.localized(.range24h)).tag(TimeRangeOption.last24Hours)
                    Text(localization.localized(.rangeToday)).tag(TimeRangeOption.today)
                    Text(localization.localized(.range7Days)).tag(TimeRangeOption.last7Days)
                    Text(localization.localized(.range30Days)).tag(TimeRangeOption.last30Days)
                    Text(localization.localized(.range1Year)).tag(TimeRangeOption.pastYear)
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                if !availableYears.isEmpty {
                    Menu {
                        ForEach(availableYears, id: \.self) { year in
                            Button(String(year)) {
                                selectedRange = .year(year)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if case .year(let y) = selectedRange {
                                Text(String(y)).bold()
                            } else {
                                Text(localization.localized(.years))
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }

    // MARK: - Agent Filter

    private var agentFilterSection: some View {
        AgentFilterBarView(
            selectedAgent: selectedToolFilter,
            availableAgents: availableAgents,
            localization: localization
        ) { agent in
            selectedToolFilter = agent
            selectedCell = nil
        }
    }

    // MARK: - KPI Cards

    private var kpiSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ], spacing: 16) {
            kpiCard(
                title: localization.localized(.periodTokens),
                value: TokenFormatter.formatCompact(periodMetrics?.totalTokens ?? 0),
                subtitle: localization.localized(.totalTokensSuffix, arguments: rangeSubtitle),
                icon: "flame.fill",
                color: .purple
            )
            .help(TokenFormatter.formatWithTooltip(periodMetrics?.totalTokens ?? 0).tooltip)
            kpiCard(
                title: localization.localized(.todaysTokens),
                value: TokenFormatter.formatCompact(todaySummary?.totalTokens ?? 0),
                subtitle: localization.localized(.rangeToday),
                icon: "bolt.fill",
                color: .blue
            )
            .help(TokenFormatter.formatWithTooltip(todaySummary?.totalTokens ?? 0).tooltip)
            kpiCard(
                title: localization.localized(.periodSpend),
                value: PricingEngine.shared.spendString(periodMetrics?.totalCostUSD ?? 0.0),
                subtitle: localization.localized(.spendSuffix, arguments: rangeSubtitle),
                icon: "dollarsign.circle.fill",
                color: .green
            )
            kpiCard(
                title: localization.localized(.mostActiveAgent),
                value: AgentFilterBarView.displayName(for: periodMetrics?.mostActiveTool ?? localization.localized(.none)),
                subtitle: localization.localized(.leadingVolume),
                icon: "sparkles",
                color: .orange
            )
        }
    }

    // MARK: - Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localization.localized(.tokenActivity, arguments: heatmapTitle), systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text(localization.localized(.activeDaysCount, arguments: heatmapCells.filter { $0.totalTokens > 0 }.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HeatmapGridView(
                cells: heatmapCells,
                selectedDayKey: selectedCell?.dayKey,
                localization: localization
            ) { cell in
                selectedCell = (selectedCell?.dayKey == cell.dayKey) ? nil : cell
            }

            if let cell = selectedCell, cell.totalTokens > 0 {
                dayInspectionBanner(cell: cell)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func dayInspectionBanner(cell: HeatmapDayCell) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localization.localized(.activityOnDay, arguments: cell.dayKey))
                    .font(.headline)
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
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            let formattedTokens = "\(TokenFormatter.formatCompact(cell.totalTokens)) (\(TokenFormatter.formatFull(cell.totalTokens)))"
            Text(localization.localized(.activityDetail, arguments: formattedTokens, String(format: "%.3f", cell.costUSD)))
                .foregroundColor(.secondary)
            if !cell.toolBreakdown.isEmpty {
                HStack(spacing: 8) {
                    ForEach(cell.toolBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { tool, count in
                        HStack(spacing: 4) {
                            Circle().fill(AgentFilterBarView.brandColor(for: tool)).frame(width: 6, height: 6)
                            Text("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatCompact(count))")
                                .font(.caption)
                                .help("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatFull(count)) tokens")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AgentFilterBarView.brandColor(for: tool).opacity(0.12))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Charts

    private var chartsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            donutChart
            trendChart
        }
    }

    private var donutChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.localized(.toolShareBreakdown, arguments: rangeSubtitle))
                .font(.headline)
            if toolDistribution.contains(where: { $0.tokens > 0 }) {
                Chart(toolDistribution.filter { $0.tokens > 0 }, id: \.tool) { item in
                    SectorMark(
                        angle: .value("Tokens", item.tokens),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Tool", AgentFilterBarView.displayName(for: item.tool)))
                }
                .frame(height: 220)
                .chartLegend(position: .bottom, spacing: 12)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chart.pie")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(localization.localized(.noToolData, arguments: rangeSubtitle))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(height: 220)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(trendTitle)
                .font(.headline)
            let trendPoints = periodMetrics?.trendPoints ?? []
            if trendPoints.contains(where: { $0.tokens > 0 }) {
                Chart(trendPoints) { item in
                    BarMark(
                        x: .value("Period", item.label),
                        y: .value("Tokens", item.tokens)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(4)
                }
                .frame(height: 220)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chart.bar")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(localization.localized(.noActivityRecorded, arguments: rangeSubtitle))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(height: 220)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Top Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localization.localized(.topProjectsDrillDown))
                    .font(.headline)
                Spacer()
                Text(localization.localized(.trackedProjectsCount, arguments: projectRankings.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if projectRankings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(localization.localized(.noProjectFoldersRecorded))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                let maxTokens = max(projectRankings.first?.totalTokens ?? 1, 1)
                VStack(spacing: 8) {
                    ForEach(Array(projectRankings.enumerated()), id: \.element.project) { index, item in
                        HStack(spacing: 12) {
                            medalBadge(rank: index + 1)
                                .frame(width: 28, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.project)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.project)

                                GeometryReader { geo in
                                    let ratio = CGFloat(item.totalTokens) / CGFloat(maxTokens)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.15))
                                        Capsule().fill(progressColor(rank: index + 1).opacity(0.75))
                                            .frame(width: max(4, geo.size.width * ratio))
                                    }
                                }
                                .frame(height: 4)
                            }

                            Spacer(minLength: 20)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(localization.localized(.tokensCount, arguments: TokenFormatter.formatCompact(item.totalTokens)))
                                    .font(.subheadline).bold()
                                    .help("\(TokenFormatter.formatFull(item.totalTokens)) tokens")
                                Text(PricingEngine.shared.spendString(item.costUSD))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func medalBadge(rank: Int) -> some View {
        switch rank {
        case 1:
            Text("🥇")
                .font(.subheadline)
        case 2:
            Text("🥈")
                .font(.subheadline)
        case 3:
            Text("🥉")
                .font(.subheadline)
        default:
            Text("#\(rank)")
                .font(.subheadline).bold()
                .foregroundColor(.secondary)
        }
    }

    private func progressColor(rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 1.0, green: 0.84, blue: 0.0)    // Gold
        case 2: return Color(red: 0.75, green: 0.75, blue: 0.78)  // Silver
        case 3: return Color(red: 0.80, green: 0.50, blue: 0.20)  // Bronze
        default: return .blue
        }
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

    private func loadData() async {
        availableYears = (try? await aggregator.fetchAvailableYears()) ?? []
        todaySummary = try? await aggregator.fetchTodaySummary()
        periodMetrics = try? await aggregator.fetchPeriodMetrics(range: selectedRange, toolFilter: selectedToolFilter)
        heatmapCells = (try? await aggregator.fetchHeatmap(range: selectedRange, toolFilter: selectedToolFilter)) ?? []
    }
}
