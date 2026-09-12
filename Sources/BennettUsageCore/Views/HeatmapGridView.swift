import SwiftUI

public struct HeatmapGridView: View {
    public let cells: [HeatmapDayCell]
    public let selectedDayKey: String?
    public let onSelectDay: ((HeatmapDayCell) -> Void)?
    public let localization: LocalizationManager


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
            grid

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

    private var grid: some View {
        let weeks = self.weeks
        return HStack(spacing: 3) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(0..<7) { dayIndex in
                        if dayIndex < week.count, let cell = week[dayIndex] {
                            HeatmapDayCellView(
                                cell: cell,
                                isSelected: cell.dayKey == selectedDayKey,
                                localization: localization
                            ) { onSelectDay?($0) }
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

}


/// A single day square. Hover/tooltip state is deliberately kept here — not on
/// the grid — so crossing one square re-renders only that square instead of
/// re-diffing the whole 371-cell grid and reformatting every tooltip. The
/// custom `==` lets SwiftUI skip unchanged squares when the parent re-renders.
/// `drawingGroup` was removed: with interactive controls (hover/tap/help) the
/// render-server round-trip costs more than plain layer drawing of solid rects.
private struct HeatmapDayCellView: View {
    let cell: HeatmapDayCell
    let isSelected: Bool
    let localization: LocalizationManager
    let onSelect: (HeatmapDayCell) -> Void

    @State private var isHovered = false

    static func == (lhs: HeatmapDayCellView, rhs: HeatmapDayCellView) -> Bool {
        lhs.cell == rhs.cell
            && lhs.isSelected == rhs.isSelected
            && lhs.localization === rhs.localization
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(colorFor(intensity: cell.intensityLevel))
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
            }
            .onHover { isHovered = $0 }
            .onTapGesture { onSelect(cell) }
            // Formatted lazily: only the hovered square builds its tooltip
            // string; every other square carries an empty (never-shown) one.
            .help(isHovered ? tooltipText(for: cell) : "")
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

/// MainActor-isolated conformance: `View` infers `@MainActor` on the struct,
/// so the custom `==` is MainActor-isolated too. SwiftUI diffs on the main
/// actor, so an isolated conformance is both correct and required here.
extension HeatmapDayCellView: @MainActor Equatable {}
