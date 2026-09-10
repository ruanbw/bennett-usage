import SwiftUI
import Charts

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var todaySummary: TodaySummary?
    @State private var annualSummary: (annualTokens: Int, annualCostUSD: Double, mostActiveTool: String)?
    @State private var toolDistribution: [(tool: String, tokens: Int, costUSD: Double)] = []
    @State private var projectRankings: [(project: String, totalTokens: Int, costUSD: Double)] = []
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedCell: HeatmapDayCell?

    public init(aggregator: MetricsAggregator) {
        self.aggregator = aggregator
    }

    private struct MonthlyUsage: Identifiable {
        var id: String { month }
        let month: String
        let tokens: Int
        let costUSD: Double
    }

    private var monthlyTrend: [MonthlyUsage] {
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var tokensByMonth = Array(repeating: 0, count: 12)
        var costByMonth = Array(repeating: 0.0, count: 12)

        for cell in heatmapCells {
            let parts = cell.dayKey.split(separator: "-")
            if parts.count >= 2, let monthNum = Int(parts[1]), monthNum >= 1 && monthNum <= 12 {
                tokensByMonth[monthNum - 1] += cell.totalTokens
                costByMonth[monthNum - 1] += cell.costUSD
            }
        }

        return (0..<12).map { i in
            MonthlyUsage(month: monthNames[i], tokens: tokensByMonth[i], costUSD: costByMonth[i])
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header & 4 KPI cards
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bennett Usage Analytics")
                                .font(.title2).bold()
                            Text("Unified local AI agent token usage, activity, and cost tracking")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("Year", selection: $selectedYear) {
                            ForEach([selectedYear - 1, selectedYear, selectedYear + 1], id: \.self) { year in
                                Text(String(year)).tag(year)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ], spacing: 16) {
                        kpiCard(
                            title: "Annual Tokens Total",
                            value: (annualSummary?.annualTokens ?? 0).formatted(),
                            subtitle: "\(String(selectedYear)) Total",
                            icon: "flame.fill",
                            color: .purple
                        )
                        kpiCard(
                            title: "Today's Tokens",
                            value: (todaySummary?.totalTokens ?? 0).formatted(),
                            subtitle: "Today",
                            icon: "bolt.fill",
                            color: .blue
                        )
                        kpiCard(
                            title: "Total Estimated Spend ($ / ¥)",
                            value: spendString(annualSummary?.annualCostUSD ?? 0.0),
                            subtitle: "\(String(selectedYear)) Spend",
                            icon: "dollarsign.circle.fill",
                            color: .green
                        )
                        kpiCard(
                            title: "Most Active Agent Tool",
                            value: toolDisplayName(annualSummary?.mostActiveTool ?? "None"),
                            subtitle: "Leading Volume",
                            icon: "sparkles",
                            color: .orange
                        )
                    }
                }

                // GitHub Heatmap Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Token Activity (\(String(selectedYear)))", systemImage: "calendar")
                            .font(.headline)
                        Spacer()
                        Text("\(heatmapCells.filter { $0.totalTokens > 0 }.count) active days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HeatmapGridView(cells: heatmapCells) { cell in
                        selectedCell = cell
                    }

                    // Selected Day Info
                    if let cell = selectedCell, cell.totalTokens > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Activity on \(cell.dayKey)")
                                .font(.headline)
                            Text("Total Tokens: \(cell.totalTokens.formatted()) · Cost: $\(String(format: "%.3f", cell.costUSD))")
                                .foregroundColor(.secondary)
                            if !cell.toolBreakdown.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(cell.toolBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { tool, count in
                                        HStack(spacing: 4) {
                                            Circle().fill(toolColor(for: tool)).frame(width: 6, height: 6)
                                            Text("\(toolDisplayName(tool)): \(count.formatted())")
                                                .font(.caption)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(toolColor(for: tool).opacity(0.12))
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
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Charts Section: Tool-Share Donut + Monthly Trend Bar Chart
                HStack(alignment: .top, spacing: 16) {
                    // Tool-Share Donut Chart
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tool Share Breakdown")
                            .font(.headline)
                        if toolDistribution.contains(where: { $0.tokens > 0 }) {
                            Chart(toolDistribution.filter { $0.tokens > 0 }, id: \.tool) { item in
                                SectorMark(
                                    angle: .value("Tokens", item.tokens),
                                    innerRadius: .ratio(0.58),
                                    angularInset: 1.5
                                )
                                .cornerRadius(4)
                                .foregroundStyle(by: .value("Tool", toolDisplayName(item.tool)))
                            }
                            .frame(height: 220)
                            .chartLegend(position: .bottom, spacing: 12)
                        } else {
                            VStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "chart.pie")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("No tool data for \(String(selectedYear))")
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

                    // Monthly Activity Trend
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Monthly Token Trend")
                            .font(.headline)
                        if monthlyTrend.contains(where: { $0.tokens > 0 }) {
                            Chart(monthlyTrend) { item in
                                BarMark(
                                    x: .value("Month", item.month),
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
                                Text("No monthly activity recorded")
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

                // Project Drill-Down List
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Top Projects Drill-Down")
                            .font(.headline)
                        Spacer()
                        Text("\(projectRankings.count) tracked")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if projectRankings.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("No project folders recorded yet")
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
                                    Text("#\(index + 1)")
                                        .font(.subheadline).bold()
                                        .foregroundColor(.secondary)
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
                                                Capsule().fill(Color.blue.opacity(0.75))
                                                    .frame(width: max(4, geo.size.width * ratio))
                                            }
                                        }
                                        .frame(height: 4)
                                    }

                                    Spacer(minLength: 20)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(item.totalTokens.formatted()) tokens")
                                            .font(.subheadline).bold()
                                        Text("$\(String(format: "%.3f", item.costUSD))")
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
            .padding(24)
        }
        .frame(minWidth: 960, minHeight: 700)
        .task(id: selectedYear) {
            await loadData(for: selectedYear)
        }
    }

    private func loadData(for year: Int) async {
        todaySummary = try? await aggregator.fetchTodaySummary()
        heatmapCells = (try? await aggregator.fetchAnnualHeatmap(year: year)) ?? []
        annualSummary = try? await aggregator.fetchAnnualSummary(year: year)
        toolDistribution = (try? await aggregator.fetchToolDistribution(year: year)) ?? []
        projectRankings = (try? await aggregator.fetchProjectRankings(limit: 10)) ?? []
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
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
            }
            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .cornerRadius(10)
    }

    private func toolDisplayName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "pi": return "Pi Agent"
        case "omp": return "Oh My Pi"
        case "claude": return "Claude Code"
        case "codex": return "OpenAI Codex"
        default: return tool.capitalized
        }
    }

    private func toolColor(for tool: String) -> Color {
        switch tool.lowercased() {
        case "pi": return Color(red: 0.06, green: 0.73, blue: 0.51)
        case "omp": return Color(red: 0.96, green: 0.62, blue: 0.04)
        case "claude": return Color(red: 0.85, green: 0.45, blue: 0.25)
        case "codex": return Color(red: 0.12, green: 0.63, blue: 0.95)
        default: return .purple
        }
    }

    private func spendString(_ costUSD: Double) -> String {
        let cny = costUSD * PricingEngine.shared.usdToCnyRate
        return "$\(String(format: "%.2f", costUSD)) / ¥\(String(format: "%.2f", cny))"
    }
}
