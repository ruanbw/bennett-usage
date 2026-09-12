import SwiftUI

public struct HeatmapGridView: View {
    public let cells: [HeatmapDayCell]
    public let selectedDayKey: String?
    public let onSelectDay: ((HeatmapDayCell) -> Void)?
    public let localization: LocalizationManager

    @State private var hoveredCell: HeatmapDayCell?

    public init(
        cells: [HeatmapDayCell],
        selectedDayKey: String? = nil,
        localization: LocalizationManager = .shared,
        onSelectDay: ((HeatmapDayCell) -> Void)? = nil
    ) {
        self.cells = cells
        self.selectedDayKey = selectedDayKey
        self.localization = localization
        self.onSelectDay = onSelectDay
    }
    /// Weeks aligned to the calendar: column 0 starts at `firstWeekday`, and the
    /// leading slots of the first week are `nil` placeholders so that a given
    /// weekday always renders in the same row (GitHub-style calendar layout).
    public var weeks: [[HeatmapDayCell?]] {
        guard let first = cells.first else { return [] }
        let calendar = Calendar.current
        let leading = ((calendar.component(.weekday, from: first.date) - calendar.firstWeekday) % 7 + 7) % 7
        var result: [[HeatmapDayCell?]] = []
        var currentWeek: [HeatmapDayCell?] = Array(repeating: nil, count: leading)
        for cell in cells {
            currentWeek.append(cell)
            if currentWeek.count == 7 {
                result.append(currentWeek)
                currentWeek = []
            }
        }
        if !currentWeek.isEmpty {
            // Pad the trailing week to 7 slots so every row renders the same
            // grid shape (GitHub-style calendar layout).
            currentWeek.append(contentsOf: Array(repeating: nil, count: 7 - currentWeek.count))
            result.append(currentWeek)
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(0..<7) { dayIndex in
                            if dayIndex < week.count, let cell = week[dayIndex] {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colorFor(intensity: cell.intensityLevel))
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(
                                                cell.dayKey == selectedDayKey ? Color.accentColor :
                                                hoveredCell?.id == cell.id ? Color.primary : Color.clear,
                                                lineWidth: cell.dayKey == selectedDayKey ? 1.5 : 1
                                            )
                                    )
                                    .onHover { isHovered in
                                        hoveredCell = isHovered ? cell : nil
                                    }
                                    .onTapGesture {
                                        onSelectDay?(cell)
                                    }
                                    .help(tooltipText(for: cell))
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Legend
            HStack(spacing: 4) {
                Spacer()
                Text(localization.localized(.less)).font(.caption2).foregroundColor(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorFor(intensity: level))
                        .frame(width: 10, height: 10)
                }
                Text(localization.localized(.more)).font(.caption2).foregroundColor(.secondary)
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
            return localization.localized(.noTokenUsage, arguments: cell.dayKey)
        }
        let formattedTokens = "\(TokenFormatter.formatCompact(cell.totalTokens)) (\(TokenFormatter.formatFull(cell.totalTokens)))"
        let detail = localization.localized(.activityDetail, arguments: formattedTokens, String(format: "%.3f", cell.costUSD))
        return "\(cell.dayKey)\n\(detail)"
    }
}

#Preview {
    HeatmapGridView(
        cells: (0..<91).reversed().map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dayKey = formatter.string(from: date)
            let tokens = (i % 3 == 0) ? 0 : Int.random(in: 10_000...500_000)
            return HeatmapDayCell(
                date: date,
                dayKey: dayKey,
                totalTokens: tokens,
                costUSD: Double(tokens) * 0.000003,
                intensityLevel: tokens == 0 ? 0 : Int.random(in: 1...4),
                toolBreakdown: ["claude": tokens]
            )
        }
    )
    .padding()
}
