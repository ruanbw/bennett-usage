import SwiftUI

public struct HeatmapGridView: View {
    public let cells: [HeatmapDayCell]
    public let onSelectDay: ((HeatmapDayCell) -> Void)?

    @State private var hoveredCell: HeatmapDayCell?

    public init(cells: [HeatmapDayCell], onSelectDay: ((HeatmapDayCell) -> Void)? = nil) {
        self.cells = cells
        self.onSelectDay = onSelectDay
    }

    public var weeks: [[HeatmapDayCell]] {
        var result: [[HeatmapDayCell]] = []
        var currentWeek: [HeatmapDayCell] = []
        for cell in cells {
            currentWeek.append(cell)
            if currentWeek.count == 7 {
                result.append(currentWeek)
                currentWeek = []
            }
        }
        if !currentWeek.isEmpty {
            result.append(currentWeek)
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colorFor(intensity: cell.intensityLevel))
                                .frame(width: 11, height: 11)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(hoveredCell?.id == cell.id ? Color.primary : Color.clear, lineWidth: 1)
                                )
                                .onHover { isHovered in
                                    hoveredCell = isHovered ? cell : nil
                                }
                                .onTapGesture {
                                    onSelectDay?(cell)
                                }
                                .help(tooltipText(for: cell))
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.caption2).foregroundColor(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorFor(intensity: level))
                        .frame(width: 10, height: 10)
                }
                Text("More").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    private func colorFor(intensity: Int) -> Color {
        switch intensity {
        case 1: return Color.green.opacity(0.3)
        case 2: return Color.green.opacity(0.55)
        case 3: return Color.green.opacity(0.8)
        case 4: return Color.green
        default: return Color(NSColor.separatorColor).opacity(0.2)
        }
    }

    private func tooltipText(for cell: HeatmapDayCell) -> String {
        guard cell.totalTokens > 0 else {
            return "\(cell.dayKey): No token usage"
        }
        return "\(cell.dayKey)\nTotal Tokens: \(cell.totalTokens.formatted())\nCost: $\(String(format: "%.3f", cell.costUSD))"
    }
}
