import Foundation
import SwiftUI

public struct HeatmapGridView: View {
    public let cells: [HeatmapDayCell]
    public let selectedDayKey: String?
    public let onSelectDay: ((HeatmapDayCell) -> Void)?
    public let localization: LocalizationManager
    public let pricingEngine: PricingEngine


    public init(
        cells: [HeatmapDayCell],
        selectedDayKey: String? = nil,
        localization: LocalizationManager = .shared,
        pricingEngine: PricingEngine = .shared,
        onSelectDay: ((HeatmapDayCell) -> Void)? = nil
    ) {
        self.cells = cells
        self.selectedDayKey = selectedDayKey
        self.localization = localization
        self.pricingEngine = pricingEngine
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

    /// Human-readable date announced for a day button. `dayKey` remains the
    /// stable storage/identity value; it is intentionally not used as the
    /// spoken date because an ISO key is difficult to hear and understand.
    public static func accessibilityLabel(
        for cell: HeatmapDayCell,
        localization: LocalizationManager = .shared
    ) -> String {
        let style = Date.FormatStyle(date: .long, time: .omitted)
            .locale(Locale(identifier: localization.effectiveLanguage.code))
        return cell.date.formatted(style)
    }

    /// Value announced with a day's date label for VoiceOver.
    public static func accessibilityValue(
        for cell: HeatmapDayCell,
        localization: LocalizationManager = .shared,
        pricingEngine: PricingEngine = .shared
    ) -> String {
        guard cell.totalTokens > 0 else {
            // `noTokenUsage` includes a date placeholder for the visible tooltip.
            // Ask for the date-free form instead of stripping a known number of
            // characters, which keeps this value correct for every locale.
            let noUsage = localization.localized(.noTokenUsage, arguments: "")
            return noUsage.trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
        }
        let formattedTokens = "\(TokenFormatter.formatCompact(cell.totalTokens)) (\(TokenFormatter.formatFull(cell.totalTokens)))"
        return localization.localized(
            .activityDetail,
            arguments: formattedTokens,
            pricingEngine.spendString(cell.costUSD)
        )
    }

    /// Action/state hint for a day. Empty days remain actionable Buttons, but
    /// explicitly say why there is no value; selecting the same day again clears
    /// the dashboard's day focus.
    public static func accessibilityHint(
        for cell: HeatmapDayCell,
        isSelected: Bool,
        localization: LocalizationManager = .shared
    ) -> String {
        if isSelected {
            return localization.localized(.clearFocus)
        }
        if cell.totalTokens == 0 {
            return localization.localized(
                .noActivityRecorded,
                arguments: accessibilityLabel(for: cell, localization: localization)
            )
        }
        return localization.localized(
            .activityOnDay,
            arguments: accessibilityLabel(for: cell, localization: localization)
        )
    }

    /// A short aggregate description for the heatmap container. Individual day
    /// buttons remain available below this summary so VoiceOver and keyboard
    /// users can inspect a specific date without hearing 365 values at once.
    public static func accessibilitySummary(
        for cells: [HeatmapDayCell],
        localization: LocalizationManager = .shared,
        pricingEngine: PricingEngine = .shared
    ) -> String {
        let boardName = localization.localized(.heatmapView)
        guard !cells.isEmpty else {
            return localization.localized(.noActivityRecorded, arguments: boardName)
        }

        var totalTokens = 0
        var totalCostUSD = 0.0
        var activeDays = 0
        for cell in cells {
            totalTokens += cell.totalTokens
            totalCostUSD += cell.costUSD
            if cell.totalTokens > 0 {
                activeDays += 1
            }
        }

        let total = "\(TokenFormatter.formatCompact(totalTokens)) \(localization.localized(.tokenUnit))"
        let active = localization.localized(.activeDaysCount, arguments: activeDays)
        let spend = "\(localization.localized(.estimatedCost)) \(pricingEngine.spendString(totalCostUSD))"
        if localization.effectiveLanguage.code == AppLanguage.zh.code {
            return "\(boardName)：\(total)，\(active) / \(cells.count) 天，\(spend)。"
        }
        return "\(boardName): \(total), \(active) of \(cells.count) days, \(spend)."
    }

    /// Traits applied to a day button. Day controls are native Buttons and
    /// expose the keyboard-key trait alongside their selected state; the
    /// optional focus argument documents the live focus state for callers that
    /// render a focus indicator themselves.
    public static func accessibilityTraits(isSelected: Bool) -> AccessibilityTraits {
        var traits: AccessibilityTraits = [.isButton, .isKeyboardKey]
        if isSelected {
            traits = traits.union(.isSelected)
        }
        return traits
    }

    public static func accessibilityTraits(
        isSelected: Bool,
        isKeyboardFocused: Bool
    ) -> AccessibilityTraits {
        var traits = accessibilityTraits(isSelected: isSelected)
        if isKeyboardFocused {
            traits = traits.union(.isKeyboardKey)
        }
        return traits
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid

            // Legend
            HStack(spacing: 4) {
                Spacer()
                Text(localization.localized(.less))
                    .font(.caption2)
                    .foregroundColor(AppTheme.Text.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(AppTheme.Heatmap.color(for: level))
                        .frame(width: 11, height: 11)
                }
                Text(localization.localized(.more))
                    .font(.caption2)
                    .foregroundColor(AppTheme.Text.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
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
                                localization: localization,
                                pricingEngine: pricingEngine
                            ) { onSelectDay?($0) }
                        } else {
                            Color.clear
                                .frame(width: 11, height: 11)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.localized(.heatmapView))
        .accessibilityValue(HeatmapGridView.accessibilitySummary(
            for: cells,
            localization: localization,
            pricingEngine: pricingEngine
        ))
        .accessibilityAddTraits(.isSummaryElement)
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
    let pricingEngine: PricingEngine
    let onSelect: (HeatmapDayCell) -> Void

    @State private var isHovered = false
    @FocusState private var isKeyboardFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    private var hasFocus: Bool {
        isKeyboardFocused || isAccessibilityFocused
    }

    static func == (lhs: HeatmapDayCellView, rhs: HeatmapDayCellView) -> Bool {
        lhs.cell == rhs.cell
            && lhs.isSelected == rhs.isSelected
            && lhs.localization === rhs.localization
            && lhs.pricingEngine === rhs.pricingEngine
    }

    var body: some View {
        Button {
            onSelect(cell)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(colorFor(intensity: cell.intensityLevel))

                // The check mark is deliberately shape-based feedback: the
                // selected state must remain distinguishable without color.
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(AppTheme.Text.primary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 11, height: 11)
            .overlay {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(
                            isSelected ? AppTheme.Status.accent : AppTheme.Text.primary,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
            }
            .overlay {
                if hasFocus {
                    // A dashed outer ring distinguishes keyboard/VoiceOver
                    // focus from selection, which uses a solid ring + check.
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            AppTheme.Border.focus,
                            style: StrokeStyle(lineWidth: 2, dash: [2, 1])
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isKeyboardFocused)
        .accessibilityFocused($isAccessibilityFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(HeatmapGridView.accessibilityLabel(
            for: cell,
            localization: localization
        ))
        .accessibilityValue(HeatmapGridView.accessibilityValue(
            for: cell,
            localization: localization,
            pricingEngine: pricingEngine
        ))
        .accessibilityHint(HeatmapGridView.accessibilityHint(
            for: cell,
            isSelected: isSelected,
            localization: localization
        ))
        .accessibilityAddTraits(HeatmapGridView.accessibilityTraits(
            isSelected: isSelected,
            isKeyboardFocused: hasFocus
        ))
        // Formatted lazily: only the hovered square builds its tooltip
        // string; every other square carries an empty (never-shown) one.
        .help(isHovered ? tooltipText(for: cell) : "")
    }

    private func colorFor(intensity: Int) -> Color {
        AppTheme.Heatmap.color(for: intensity)
    }

    private func tooltipText(for cell: HeatmapDayCell) -> String {
        guard cell.totalTokens > 0 else {
            return localization.localized(.noTokenUsage, arguments: cell.dayKey)
        }
        let formattedTokens = "\(TokenFormatter.formatCompact(cell.totalTokens)) (\(TokenFormatter.formatFull(cell.totalTokens)))"
        let detail = localization.localized(
            .activityDetail,
            arguments: formattedTokens,
            pricingEngine.spendString(cell.costUSD)
        )
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
