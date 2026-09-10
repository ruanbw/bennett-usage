import SwiftUI
import Charts

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @State private var heatmapCells: [HeatmapDayCell] = []
    @State private var todaySummary: TodaySummary?
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedCell: HeatmapDayCell?

    public init(aggregator: MetricsAggregator) {
        self.aggregator = aggregator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header & KPI cards
                HStack(spacing: 16) {
                    kpiCard(title: "Today's Tokens", value: (todaySummary?.totalTokens ?? 0).formatted(), icon: "bolt.fill", color: .blue)
                    kpiCard(title: "Today's Cost", value: "$\(String(format: "%.2f", todaySummary?.totalCostUSD ?? 0.0))", icon: "dollarsign.circle.fill", color: .green)
                    kpiCard(title: "Annual Active Days", value: "\(heatmapCells.filter { $0.totalTokens > 0 }.count) days", icon: "calendar", color: .orange)
                }

                // Heatmap Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Token Activity (\(String(selectedYear)))")
                            .font(.title3).bold()
                        Spacer()
                    }

                    HeatmapGridView(cells: heatmapCells) { cell in
                        selectedCell = cell
                    }
                }

                // Selected Day Info
                if let cell = selectedCell, cell.totalTokens > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Activity on \(cell.dayKey)")
                            .font(.headline)
                        Text("Total Tokens: \(cell.totalTokens.formatted()) · Cost: $\(String(format: "%.3f", cell.costUSD))")
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            todaySummary = try? await aggregator.fetchTodaySummary()
            heatmapCells = (try? await aggregator.fetchAnnualHeatmap(year: selectedYear)) ?? []
        }
    }

    private func kpiCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.title2).bold()
            }
            Spacer()
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
