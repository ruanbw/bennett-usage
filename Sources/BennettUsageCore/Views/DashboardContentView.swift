import SwiftUI
import Charts
import AppKit

public enum TrendChartType: String, CaseIterable, Identifiable {
    case bar
    case line

    public var id: String { rawValue }
}

public enum HeatmapDisplayMode: String, CaseIterable, Identifiable {
    case calendar
    case monthlyTrend

    public var id: String { rawValue }
}

public struct DashboardContentView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager
    public let onOpenSettings: (() -> Void)?

    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var todaySummary: TodaySummary?
    @State private var periodMetrics: PeriodMetrics?
    @State private var selectedRange: TimeRangeOption
    @State private var availableYears: [Int] = []
    @State private var selectedCell: HeatmapDayCell?
    @State private var selectedToolFilter: String?
    @State private var trendChartType: TrendChartType = .bar
    @State private var hoveredTrendPeriod: String? = nil
    @State private var hoveredTool: String? = nil
    @State private var hoveredModel: String? = nil
    @State private var trendHoverLocation: CGPoint? = nil
    @State private var toolHoverLocation: CGPoint? = nil
    @State private var modelHoverLocation: CGPoint? = nil
    @State private var isProjectsExpanded: Bool = false
    @State private var allTimeTotals: AllTimeTotals? = nil
    @State private var refreshTick = 0
    @State private var lastDataUpdateLoad: Date = .distantPast
    @State private var selectedHeatmapYear: Int = Calendar.current.component(.year, from: Date())
    @State private var annualSummary: (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String, activeDays: Int, totalDays: Int)? = nil
    @State private var annualTrendPoints: [TrendPoint] = []
    @State private var heatmapDisplayMode: HeatmapDisplayMode = .calendar
    @State private var hoveredAnnualMonth: String? = nil
    @State private var annualMonthHoverLocation: CGPoint? = nil

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared,
        initialRange: TimeRangeOption = .last24Hours,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.aggregator = aggregator
        self.localization = localization
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
        return localization.localized(.yearTitle, arguments: String(selectedHeatmapYear))
    }

    private var toolDistribution: [(tool: String, tokens: Int, costUSD: Double)] {
        periodMetrics?.toolDistribution ?? []
    }
    private var modelDistribution: [(model: String, tokens: Int, costUSD: Double)] {
        periodMetrics?.modelDistribution ?? []
    }
    private var agentColors: [String: Color] {
        ChartPalette.shared.colors(for: availableAgents)
    }
    private var modelColors: [String: Color] {
        ChartPalette.shared.colors(for: modelDistribution.map(\.model))
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
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                agentFilterSection
                heroSection
                trendChart
                distributionChartsSection
                heatmapSection
                projectsSection
            }
            .padding(24)
        }
        .task(id: "\(selectedRange)_\(selectedHeatmapYear)_\(selectedToolFilter ?? "all")_\(refreshTick)") {
            await loadData()
        }
        .task {
            await autoRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bennettUsageDataDidUpdate)) { _ in
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

    private var headerSection: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedRange) {
                Text(localization.localized(.range24h)).tag(TimeRangeOption.last24Hours)
                Text(localization.localized(.rangeToday)).tag(TimeRangeOption.today)
                Text(localization.localized(.range7Days)).tag(TimeRangeOption.last7Days)
                Text(localization.localized(.range30Days)).tag(TimeRangeOption.last30Days)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)

            if case .year(let y) = selectedRange {
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11))
                    Text(localization.localized(.viewingAnnualDashboard, arguments: String(y)))
                        .font(.caption)
                        .fontWeight(.medium)
                    Button {
                        selectedRange = .last30Days
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localization.localized(.exitAnnualDashboard))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            }

            Spacer()

            if let onOpenSettings = onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(localization.localized(.settings))
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


    private var heroSection: some View {
        VStack(spacing: 16) {
            // Top Row
            HStack(alignment: .center) {
                // Left: Brand Icon + Titles
                HStack(spacing: 12) {
                    let brandColor = selectedToolFilter.flatMap { agentColors[$0] } ?? Color.accentColor.opacity(0.15)
                    let agentName = selectedToolFilter != nil ? AgentFilterBarView.displayName(for: selectedToolFilter!) : localization.localized(.filterAllAgents)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(brandColor)
                            .frame(width: 36, height: 36)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(selectedToolFilter != nil ? .white : .accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(agentName)
                                .bold()
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(localization.localized(.periodTokens))
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            let total = allTimeTotals?.totalTokens ?? 0
                            Text(TokenFormatter.formatFull(total))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .monospacedDigit()

                            Text("≈ \(TokenFormatter.formatCompact(total))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                }

                Spacer()

                // Right: Pill box container
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.rangeTokens, arguments: rangeSubtitle))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(TokenFormatter.formatCompact(periodMetrics?.totalTokens ?? 0))
                                .font(.subheadline)
                                .bold()
                        }
                    }
                    .help("\(TokenFormatter.formatFull(periodMetrics?.totalTokens ?? 0)) tokens")

                    Divider()
                        .frame(height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.spendSuffix, arguments: rangeSubtitle))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(PricingEngine.shared.spendString(periodMetrics?.totalCostUSD ?? 0.0))
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )
            }

            // Bottom Row: 5 mini stat cards
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                miniStatCard(
                    title: localization.localized(.freshInput),
                    icon: "arrow.down.to.line",
                    iconColor: .blue,
                    value: TokenFormatter.formatCompact(periodMetrics?.inputTokens ?? 0),
                    fullTokens: periodMetrics?.inputTokens ?? 0
                )

                miniStatCard(
                    title: localization.localized(.modelOutput),
                    icon: "arrow.up.from.line",
                    iconColor: .purple,
                    value: TokenFormatter.formatCompact(periodMetrics?.outputTokens ?? 0),
                    fullTokens: periodMetrics?.outputTokens ?? 0
                )

                miniStatCard(
                    title: localization.localized(.cacheWrite),
                    icon: "cylinder.split.1x2",
                    iconColor: .orange,
                    value: TokenFormatter.formatCompact(periodMetrics?.cacheWriteTokens ?? 0),
                    fullTokens: periodMetrics?.cacheWriteTokens ?? 0
                )

                miniStatCard(
                    title: localization.localized(.cacheRead),
                    icon: "sparkles",
                    iconColor: .green,
                    value: TokenFormatter.formatCompact(periodMetrics?.cacheReadTokens ?? 0),
                    fullTokens: periodMetrics?.cacheReadTokens ?? 0
                )
                cacheHitRateCard
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func miniStatCard(title: String, icon: String, iconColor: Color, value: String, fullTokens: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.subheadline)
                .bold()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        .cornerRadius(8)
        .help(fullTokens != nil ? "\(TokenFormatter.formatFull(fullTokens!)) tokens" : value)
    }

    private var cacheHitRateCard: some View {
        let hitRate = periodMetrics?.cacheHitRate ?? 0.0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "chart.pie.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
                Text(localization.localized(.cacheHitRate))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(String(format: "%.1f%%", hitRate * 100))
                .font(.subheadline)
                .bold()
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: max(0, min(geo.size.width * CGFloat(hitRate), geo.size.width)), height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        .cornerRadius(8)
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
                            .foregroundColor(.accentColor)
                            .font(.headline)
                        Text(localization.localized(.annualPanorama))
                            .font(.headline)
                    }
                    Text("\(String(selectedHeatmapYear))-01-01 ~ \(String(selectedHeatmapYear))-12-31")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    // Year Switcher Pills (or Menu if > 4 years)
                    if displayedYears.count <= 4 {
                        HStack(spacing: 4) {
                            ForEach(displayedYears, id: \.self) { year in
                                Button {
                                    selectedHeatmapYear = year
                                    selectedCell = nil
                                } label: {
                                    Text(String(year))
                                        .font(.caption)
                                        .fontWeight(selectedHeatmapYear == year ? .semibold : .regular)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(selectedHeatmapYear == year ? Color.accentColor : Color(NSColor.windowBackgroundColor).opacity(0.6))
                                        .foregroundColor(selectedHeatmapYear == year ? .white : .primary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
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
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                            .cornerRadius(6)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    // Display Mode Switcher (Calendar vs Monthly Trend)
                    Picker("", selection: $heatmapDisplayMode) {
                        Image(systemName: "square.grid.3x3.fill")
                            .tag(HeatmapDisplayMode.calendar)
                            .help(localization.localized(.calendarView))
                        Image(systemName: "chart.bar.xaxis")
                            .tag(HeatmapDisplayMode.monthlyTrend)
                            .help(localization.localized(.monthlyTrend))
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
                        .background(isFullDashboardYear ? Color.accentColor.opacity(0.15) : Color(NSColor.windowBackgroundColor).opacity(0.6))
                        .foregroundColor(isFullDashboardYear ? .accentColor : .secondary)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isFullDashboardYear ? Color.accentColor.opacity(0.4) : Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.8)
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
                    localization: localization
                ) { cell in
                    selectedCell = (selectedCell?.dayKey == cell.dayKey) ? nil : cell
                }

                if let cell = selectedCell, cell.totalTokens > 0 {
                    dayInspectionBanner(cell: cell)
                }
            } else {
                annualMonthlyTrendChart
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func annualMetricsStrip(summary: (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String, activeDays: Int, totalDays: Int)) -> some View {
        HStack(spacing: 0) {
            // 1. Annual Tokens
            annualStatItem(
                title: localization.localized(.annualTotalTokens),
                value: TokenFormatter.formatCompact(summary.annualTokens),
                subvalue: "\(TokenFormatter.formatFull(summary.annualTokens)) tokens",
                icon: "flame.fill",
                color: .orange
            )
            Divider().frame(height: 28).padding(.horizontal, 8)

            // 2. Annual Cost
            annualStatItem(
                title: localization.localized(.annualSpend),
                value: PricingEngine.shared.spendString(summary.annualCostUSD),
                subvalue: summary.annualCostUSD > 0 ? "USD" : "-",
                icon: "dollarsign.circle.fill",
                color: .green
            )
            Divider().frame(height: 28).padding(.horizontal, 8)

            // 3. Active Days
            let pct = summary.totalDays > 0 ? (Double(summary.activeDays) / Double(summary.totalDays) * 100.0) : 0.0
            annualStatItem(
                title: localization.localized(.annualActiveDays),
                value: "\(summary.activeDays) / \(summary.totalDays)",
                subvalue: String(format: "%.1f%%", pct),
                icon: "calendar.badge.checkmark",
                color: .blue
            )
            Divider().frame(height: 28).padding(.horizontal, 8)

            // 4. Primary Agent
            let agentName = summary.mostActiveTool != "None" ? AgentFilterBarView.displayName(for: summary.mostActiveTool) : localization.localized(.none)
            let agentColor = summary.mostActiveTool != "None" ? (agentColors[summary.mostActiveTool] ?? .purple) : .secondary
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
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func annualStatItem(title: String, value: String, subvalue: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.subheadline)
                        .bold()
                    Text(subvalue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var annualMonthlyTrendChart: some View {
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
                                        }
                                        if next != nil {
                                            annualMonthHoverLocation = loc
                                        } else {
                                            annualMonthHoverLocation = nil
                                        }
                                    case .ended:
                                        annualMonthHoverLocation = nil
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
                                    Text(PricingEngine.shared.spendString(point.costUSD))
                                        .font(.caption2)
                                        .foregroundColor(.green)
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
                            Circle().fill(agentColors[tool] ?? .gray).frame(width: 6, height: 6)
                            Text("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatCompact(count))")
                                .font(.caption)
                                .help("\(AgentFilterBarView.displayName(for: tool)): \(TokenFormatter.formatFull(count)) tokens")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((agentColors[tool] ?? .gray).opacity(0.12))
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

    private var distributionChartsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            donutChart
            modelChart
        }
    }
    private func tooltipPosition(for loc: CGPoint, in size: CGSize, tooltipSize: CGSize) -> CGPoint {
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

    private func updateHoveredDonut(
        location: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy,
        items: [(name: String, tokens: Int)],
        setHovered: (String?) -> Void
    ) {
        guard let plotFrame = proxy.plotFrame else {
            setHovered(nil)
            return
        }
        let frame = geo[plotFrame]
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let distance = sqrt(dx * dx + dy * dy)
        let maxRadius = min(Double(frame.width), Double(frame.height)) / 2.0
        let minRadius = maxRadius * 0.55
        let maxRadiusLimit = maxRadius * 1.02

        guard distance >= minRadius && distance <= maxRadiusLimit else {
            setHovered(nil)
            return
        }

        let rad = atan2(dy, dx)
        var angle = rad + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let fraction = angle / (2 * Double.pi)

        let total = items.reduce(0) { $0 + $1.tokens }
        guard total > 0 else {
            setHovered(nil)
            return
        }

        let targetVal = fraction * Double(total)
        var accum = 0.0
        for item in items {
            accum += Double(item.tokens)
            if targetVal <= accum {
                setHovered(item.name)
                return
            }
        }
        setHovered(items.last?.name)
    }

    private var donutChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.localized(.toolShareBreakdown, arguments: rangeSubtitle))
                .font(.headline)
            let activeTools = toolDistribution.filter { $0.tokens > 0 }
            if !activeTools.isEmpty {
                let totalTokens = activeTools.reduce(0) { $0 + $1.tokens }
                HStack(spacing: 16) {
                    Chart(activeTools, id: \.tool) { item in
                        SectorMark(
                            angle: .value("Tokens", item.tokens),
                            innerRadius: .ratio(0.58),
                            outerRadius: .ratio(1.0),
                            angularInset: 1.5
                        )
                        .cornerRadius(4)
                        .foregroundStyle(agentColors[item.tool] ?? .gray)
                        .opacity(hoveredTool == nil || hoveredTool == item.tool ? 1.0 : 0.45)
                    }
                    .chartLegend(.hidden)
                    .chartBackground { proxy in
                        GeometryReader { geo in
                            let frame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
                            VStack(spacing: 2) {
                                if let hovered = hoveredTool, let item = activeTools.first(where: { $0.tool == hovered }) {
                                    Text(item.tool)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text(TokenFormatter.formatCompact(item.tokens))
                                        .font(.caption).bold()
                                    let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0
                                    Text(String(format: "%.0f%%", pct))
                                        .font(.caption2)
                                        .foregroundColor(agentColors[item.tool] ?? .gray)
                                } else {
                                    Text("Total")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(TokenFormatter.formatCompact(totalTokens))
                                        .font(.caption).bold()
                                }
                            }
                            .frame(width: 86)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    .frame(width: 170, height: 170)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let loc):
                                            updateHoveredDonut(
                                                location: loc,
                                                proxy: proxy,
                                                geo: geo,
                                                items: activeTools.map { (name: $0.tool, tokens: $0.tokens) },
                                                setHovered: { next in
                                                    if hoveredTool != next {
                                                        hoveredTool = next
                                                    }
                                                    if next != nil {
                                                        toolHoverLocation = loc
                                                    } else {
                                                        toolHoverLocation = nil
                                                    }
                                                }
                                            )
                                        case .ended:
                                            toolHoverLocation = nil
                                            if hoveredTool != nil {
                                                hoveredTool = nil
                                            }
                                        }
                                    }

                                if let loc = toolHoverLocation,
                                   let hovered = hoveredTool,
                                   let item = activeTools.first(where: { $0.tool == hovered }) {
                                    let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(AgentFilterBarView.displayName(for: item.tool))
                                            .font(.caption2).bold()
                                        Text("\(TokenFormatter.formatFull(item.tokens)) tokens")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f%% · %@", pct, PricingEngine.shared.spendString(item.costUSD)))
                                            .font(.caption2)
                                        .foregroundColor(agentColors[item.tool] ?? .gray)
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
                                    .position(tooltipPosition(for: loc, in: geo.size, tooltipSize: CGSize(width: 140, height: 55)))
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                    }

                    // Vertical Legend on Right (highlighted when hovered)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(activeTools, id: \.tool) { item in
                            let isSelected = hoveredTool == item.tool
                            let color = agentColors[item.tool] ?? .gray
                            let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0

                            HStack(spacing: 6) {
                                Circle().fill(color).frame(width: 8, height: 8)
                                Text(AgentFilterBarView.displayName(for: item.tool))
                                    .font(.caption)
                                    .fontWeight(isSelected ? .bold : .regular)
                                    .lineLimit(1)
                                Spacer()
                                Text(TokenFormatter.formatCompact(item.tokens))
                                    .font(.caption)
                                    .fontWeight(isSelected ? .bold : .medium)
                                Text(String(format: "%.0f%%", pct))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? color.opacity(0.18) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? color.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                            .onHover { isHovered in
                                hoveredTool = isHovered ? item.tool : nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 200)
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
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func visibleXAxisLabels(for points: [TrendPoint]) -> [String] {
        let count = points.count
        guard count > 8 else {
            return points.map(\.label)
        }
        let step: Int
        if count <= 14 {
            step = 2
        } else if count <= 24 {
            step = 4
        } else {
            step = max(1, count / 6)
        }
        var visible: [String] = []
        for i in stride(from: 0, to: count, by: step) {
            visible.append(points[i].label)
        }
        if let last = points.last, !visible.contains(last.label) {
            let remainder = (count - 1) % step
            if remainder >= 2 {
                visible.append(last.label)
            }
        }
        return visible
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(trendTitle)
                    .font(.headline)
                Spacer()
                Picker("", selection: $trendChartType) {
                    Image(systemName: "chart.bar.fill")
                        .tag(TrendChartType.bar)
                        .help(localization.localized(.chartTypeBar))
                    Image(systemName: "chart.xyaxis.line")
                        .tag(TrendChartType.line)
                        .help(localization.localized(.chartTypeLine))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
            }

            let trendPoints = periodMetrics?.trendPoints ?? []
            if trendPoints.contains(where: { $0.tokens > 0 }) {
                let visibleLabels = visibleXAxisLabels(for: trendPoints)
                Chart {
                    ForEach(trendPoints) { item in
                        if trendChartType == .bar {
                            BarMark(
                                x: .value("Period", item.label),
                                y: .value("Tokens", item.tokens)
                            )
                            .foregroundStyle(Color.blue.gradient)
                            .cornerRadius(4)
                            .opacity(hoveredTrendPeriod == nil || hoveredTrendPeriod == item.label ? 1.0 : 0.35)
                        } else {
                            AreaMark(
                                x: .value("Period", item.label),
                                y: .value("Tokens", item.tokens)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.monotone)

                            LineMark(
                                x: .value("Period", item.label),
                                y: .value("Tokens", item.tokens)
                            )
                            .foregroundStyle(Color.blue)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))

                            if hoveredTrendPeriod == item.label {
                                PointMark(
                                    x: .value("Period", item.label),
                                    y: .value("Tokens", item.tokens)
                                )
                                .foregroundStyle(Color.blue)
                                .symbolSize(50)
                            }
                        }
                    }

                    if let hovered = hoveredTrendPeriod, trendPoints.contains(where: { $0.label == hovered }) {
                        RuleMark(x: .value("Period", hovered))
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
                                            trendHoverLocation = nil
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
                                        }
                                        if next != nil {
                                            trendHoverLocation = loc
                                        } else {
                                            trendHoverLocation = nil
                                        }
                                    case .ended:
                                        trendHoverLocation = nil
                                        if hoveredTrendPeriod != nil {
                                            hoveredTrendPeriod = nil
                                        }
                                    }
                                }

                            if let loc = trendHoverLocation,
                               let hovered = hoveredTrendPeriod,
                               let point = trendPoints.first(where: { $0.label == hovered }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.label)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(TokenFormatter.formatFull(point.tokens)) tokens")
                                        .font(.caption).bold()
                                    Text(PricingEngine.shared.spendString(point.costUSD))
                                        .font(.caption2)
                                        .foregroundColor(.green)
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
                .frame(height: 230)
                .chartXAxis {
                    AxisMarks(values: visibleLabels) { value in
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
                .frame(height: 230)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var modelChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.localized(.modelUsageBreakdown, arguments: rangeSubtitle))
                .font(.headline)

            let activeModels = Array(modelDistribution.filter { $0.tokens > 0 }.prefix(6))
            if !activeModels.isEmpty {
                let totalTokens = activeModels.reduce(0) { $0 + $1.tokens }
                HStack(spacing: 16) {
                    Chart(Array(activeModels.enumerated()), id: \.element.model) { idx, item in
                        let color = modelColors[item.model] ?? .gray
                        SectorMark(
                            angle: .value("Tokens", item.tokens),
                            innerRadius: .ratio(0.58),
                            outerRadius: .ratio(1.0),
                            angularInset: 1.5
                        )
                        .cornerRadius(4)
                        .foregroundStyle(color)
                        .opacity(hoveredModel == nil || hoveredModel == item.model ? 1.0 : 0.45)
                    }
                    .chartLegend(.hidden)
                    .chartBackground { proxy in
                        GeometryReader { geo in
                            let frame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
                            VStack(spacing: 2) {
                                if let hovered = hoveredModel, let item = activeModels.first(where: { $0.model == hovered }) {
                                    Text(item.model)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(TokenFormatter.formatCompact(item.tokens))
                                        .font(.caption).bold()
                                    let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0
                                    Text(String(format: "%.0f%%", pct))
                                        .font(.caption2)
                                        .foregroundColor(modelColors[item.model] ?? .gray)
                                } else {
                                    Text("Total")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(TokenFormatter.formatCompact(totalTokens))
                                        .font(.caption).bold()
                                }
                            }
                            .frame(width: 86)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    .frame(width: 170, height: 170)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let loc):
                                            updateHoveredDonut(
                                                location: loc,
                                                proxy: proxy,
                                                geo: geo,
                                                items: activeModels.map { (name: $0.model, tokens: $0.tokens) },
                                                setHovered: { next in
                                                    if hoveredModel != next {
                                                        hoveredModel = next
                                                    }
                                                    if next != nil {
                                                        modelHoverLocation = loc
                                                    } else {
                                                        modelHoverLocation = nil
                                                    }
                                                }
                                            )
                                        case .ended:
                                            modelHoverLocation = nil
                                            if hoveredModel != nil {
                                                hoveredModel = nil
                                            }
                                        }
                                    }

                                if let loc = modelHoverLocation,
                                   let hovered = hoveredModel,
                                   let item = activeModels.first(where: { $0.model == hovered }) {
                                    let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.model)
                                            .font(.caption2).bold()
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("\(TokenFormatter.formatFull(item.tokens)) tokens")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f%% · %@", pct, PricingEngine.shared.spendString(item.costUSD)))
                                            .font(.caption2)
                                        .foregroundColor(modelColors[item.model] ?? .gray)
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
                                    .position(tooltipPosition(for: loc, in: geo.size, tooltipSize: CGSize(width: 150, height: 55)))
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                    }

                    // Vertical Legend on Right (highlighted when hovered)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(activeModels.enumerated()), id: \.element.model) { idx, item in
                            let isSelected = hoveredModel == item.model
                            let color = modelColors[item.model] ?? .gray
                            let pct = totalTokens > 0 ? (Double(item.tokens) / Double(totalTokens) * 100) : 0

                            HStack(spacing: 6) {
                                Circle().fill(color).frame(width: 8, height: 8)
                                Text(item.model)
                                    .font(.caption)
                                    .fontWeight(isSelected ? .bold : .regular)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(TokenFormatter.formatCompact(item.tokens))
                                    .font(.caption)
                                    .fontWeight(isSelected ? .bold : .medium)
                                Text(String(format: "%.0f%%", pct))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? color.opacity(0.18) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? color.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                            .onHover { isHovered in
                                hoveredModel = isHovered ? item.model : nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 200)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(localization.localized(.noModelData, arguments: rangeSubtitle))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(height: 200)
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
                let displayedProjects = isProjectsExpanded ? projectRankings : Array(projectRankings.prefix(3))
                VStack(spacing: 8) {
                    ForEach(Array(displayedProjects.enumerated()), id: \.element.project) { index, item in
                        HStack(spacing: 12) {
                            medalBadge(rank: index + 1)
                                .frame(width: 28, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                let folderName = (item.project as NSString).lastPathComponent.isEmpty ? item.project : (item.project as NSString).lastPathComponent
                                Text(folderName)
                                    .font(.subheadline).bold()
                                    .lineLimit(1)
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
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
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

    /// Data-update notifications can arrive in bursts while agents are active;
    /// each full `loadData` re-aggregates every record in range, so collapse
    /// bursts into at most one reload per second.
    private func loadDataThrottled() async {
        let now = Date()
        guard now.timeIntervalSince(lastDataUpdateLoad) >= 1.0 else { return }
        lastDataUpdateLoad = now
        await loadData()
    }

    private func loadData() async {
        let years = (try? await aggregator.fetchAvailableYears()) ?? []
        availableYears = years
        if !years.isEmpty && !years.contains(selectedHeatmapYear) {
            selectedHeatmapYear = years.first!
        }
        if Task.isCancelled { return }
        todaySummary = try? await aggregator.fetchTodaySummary()
        if Task.isCancelled { return }
        periodMetrics = try? await aggregator.fetchPeriodMetrics(range: selectedRange, toolFilter: selectedToolFilter)
        if Task.isCancelled { return }
        heatmapCells = (try? await aggregator.fetchAnnualHeatmap(year: selectedHeatmapYear, toolFilter: selectedToolFilter)) ?? []
        if Task.isCancelled { return }
        annualSummary = try? await aggregator.fetchAnnualSummary(year: selectedHeatmapYear, toolFilter: selectedToolFilter)
        if Task.isCancelled { return }
        let annualMetrics = try? await aggregator.fetchPeriodMetrics(range: .year(selectedHeatmapYear), toolFilter: selectedToolFilter)
        annualTrendPoints = annualMetrics?.trendPoints ?? []
        if Task.isCancelled { return }
        allTimeTotals = try? await aggregator.fetchAllTimeTotals(toolFilter: selectedToolFilter)
    }

    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            let seconds = UserDefaults.standard.integer(forKey: "bennett_auto_refresh_seconds")
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { return }
                refreshTick += 1
            } else {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

#Preview {
    let db = try! DatabaseManager.inMemory()
    let aggregator = MetricsAggregator(database: db)
    return DashboardContentView(aggregator: aggregator)
        .frame(width: 900, height: 700)
}
