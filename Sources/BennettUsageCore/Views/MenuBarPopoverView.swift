import SwiftUI
import AppKit

/// Shared summary state for the menu bar popover: the popover's hosting
/// controller is built once and stays alive; publishing a new summary here
/// refreshes the view in place instead of rebuilding the whole hierarchy.
@MainActor
public final class StatusSummaryModel: ObservableObject {
    @Published public var summary: TodaySummary?
    /// Optional freshness and trend hooks for the app shell. TodaySummary does
    /// not contain sync time or time-series points, so the popover only renders
    /// a sparkline when the controller supplies real trend data.
    @Published public var lastRefreshedAt: Date?
    @Published public var trendPoints: [TrendPoint]?
    public init(
        summary: TodaySummary? = nil,
        lastRefreshedAt: Date? = nil,
        trendPoints: [TrendPoint]? = nil
    ) {
        self.summary = summary
        self.lastRefreshedAt = lastRefreshedAt
        self.trendPoints = trendPoints
    }
}

public struct MenuBarPopoverView: View {
    @ObservedObject public var model: StatusSummaryModel
    @ObservedObject public var updateChecker: UpdateChecker
    @ObservedObject var pricingEngine: PricingEngine
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void
    public let onOpenSettings: (() -> Void)?
    @ObservedObject public var localization: LocalizationManager

    public var summary: TodaySummary? { model.summary }

    public init(
        model: StatusSummaryModel,
        localization: LocalizationManager = .shared,
        updateChecker: UpdateChecker = .shared,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil,
        pricingEngine: PricingEngine = .shared
    ) {
        self.model = model
        self.localization = localization
        self.updateChecker = updateChecker
        self.pricingEngine = pricingEngine
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        let active = Self.activeTools(for: summary)
        let toolColors = ChartPalette.shared.colors(for: active.map(\.id))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Status.accent)
                Text(localization.localized(.appName))
                    .font(.headline)
                    .foregroundColor(AppTheme.Text.primary)
                Spacer(minLength: 8)
                if let onOpenSettings = onOpenSettings {
                    QuietIconButton(
                        systemName: "gearshape",
                        tooltip: localization.localized(.settings),
                        action: onOpenSettings
                    )
                    .accessibilityLabel(localization.localized(.settings))
                }
                QuietIconButton(
                    systemName: "macwindow",
                    tooltip: localization.localized(.openDashboardShortcut),
                    action: onOpenDashboard
                )
                .accessibilityLabel(localization.localized(.openDashboardShortcut))
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.localized(.todaysTokens))
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                    Text(TokenFormatter.formatCompact(summary?.totalTokens ?? 0))
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Text.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help(TokenFormatter.formatWithTooltip(summary?.totalTokens ?? 0).tooltip)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(localization.localized(.estimatedCost))
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                    Text(pricingEngine.spendString(summary?.totalCostUSD ?? 0.0))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Status.success)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .accessibilityElement(children: .combine)

            if let points = model.trendPoints,
               points.contains(where: { $0.tokens > 0 }),
               points.count > 1 {
                glanceTrend(points: points)
            }
            glanceDistribution(active: active, toolColors: toolColors)

            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(dataFreshnessText)
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundColor(AppTheme.Text.tertiary)
            .accessibilityElement(children: .combine)

            if let update = updateChecker.availableUpdate {
                updateBanner(update)
            }

            Divider()
                .overlay(AppTheme.Border.divider)

            HStack(spacing: 8) {
                Button(action: onOpenDashboard) {
                    Label(localization.localized(.navDashboard), systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(localization.localized(.openDashboardShortcut))

                if let onOpenSettings = onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(localization.localized(.settings))
                    .accessibilityLabel(localization.localized(.settings))
                }

                Button(action: onSyncNow) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(localization.localized(.syncNow))
                .accessibilityLabel(localization.localized(.syncNow))

                QuietTextButton(
                    title: localization.localized(.quit),
                    action: onQuit
                )
                .accessibilityLabel(localization.localized(.quit))
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(.regularMaterial)
    }

    private var dataFreshnessText: String {
        guard let lastRefreshedAt = model.lastRefreshedAt else {
            return localization.localized(.noToolsActiveToday)
        }
        let minutes = max(0, Int(Date().timeIntervalSince(lastRefreshedAt) / 60))
        if minutes == 0 {
            return localization.localized(.dataUpdatedJustNow)
        }
        return localization.localized(.dataUpdatedMinutesAgo, arguments: minutes)
    }

    private func glanceTrend(points: [TrendPoint]) -> some View {
        let total = points.reduce(0) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(localization.localized(.hourlyTrendToday))
                    .font(AppTheme.Typography.label)
                    .foregroundColor(AppTheme.Text.secondary)
                Spacer()
                Text(TokenFormatter.formatCompact(total))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(AppTheme.Text.primary)
            }

            SparkLine(points: points)
                .fill(AppTheme.Chart.primaryLine.gradient)
                .frame(height: 32)
                .accessibilityLabel(localization.localized(.hourlyTrendToday))
                .accessibilityValue(TokenFormatter.formatFull(total))
        }
    }

    private func glanceDistribution(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(localization.localized(.toolBreakdownToday))
                    .font(AppTheme.Typography.label)
                    .foregroundColor(AppTheme.Text.secondary)
                Spacer()
                if let activeAgent = active.first {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(toolColors[activeAgent.id] ?? AppTheme.Harmonic.color(for: activeAgent.id))
                            .frame(width: 6, height: 6)
                        Text(AgentFilterBarView.displayName(for: activeAgent.id))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(AppTheme.Text.primary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            miniDistributionBar(active: active, toolColors: toolColors)

            if active.isEmpty {
                Text(localization.localized(.noToolsActiveToday))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.tertiary)
            } else {
                ForEach(active.prefix(3), id: \.id) { tool in
                    toolRow(
                        name: AgentFilterBarView.displayName(for: tool.id),
                        tokens: tool.tokens,
                        color: toolColors[tool.id] ?? AppTheme.Agent.knownColor(for: tool.id) ?? AppTheme.Harmonic.color(for: tool.id)
                    )
                }
                if active.count > 3 {
                    Text(localization.localized(.moreToolsCount, arguments: active.count - 3))
                        .font(.caption)
                        .foregroundColor(AppTheme.Text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(localization.localized(.moreToolsCount, arguments: active.count - 3))
                }
            }
        }
    }

    // MARK: - Mini Distribution Bar

    private func miniDistributionBar(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        let totalActive = active.reduce(0) { $0 + $1.tokens }
        let accessibilityValue = Self.distributionAccessibilityValue(
            for: active,
            localization: localization
        )
        return GeometryReader { proxy in
            let totalWidth = proxy.size.width
            if active.isEmpty || totalActive <= 0 {
                Capsule()
                    .fill(AppTheme.Surface.subtle)
                    .frame(height: 4)
            } else {
                let spacing: CGFloat = 1.5
                let totalSpacing = CGFloat(max(0, active.count - 1)) * spacing
                let availableWidth = max(0, totalWidth - totalSpacing)

                HStack(spacing: spacing) {
                    ForEach(active, id: \.id) { tool in
                        let fraction = CGFloat(tool.tokens) / CGFloat(totalActive)
                        let segWidth = max(2, availableWidth * fraction)
                        (toolColors[tool.id] ?? AppTheme.Agent.knownColor(for: tool.id) ?? AppTheme.Harmonic.color(for: tool.id))
                            .frame(width: segWidth, height: 4)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.localized(.toolBreakdownToday))
        .accessibilityValue(accessibilityValue)
    }

    static func distributionAccessibilityValue(
        for active: [ActiveTool],
        localization: LocalizationManager
    ) -> String {
        let totalTokens = active.reduce(0) { $0 + $1.tokens }
        guard totalTokens > 0 else { return localization.localized(.noToolsActiveToday) }

        let tokenUnit = localization.localized(.tokenUnit)
        return active.map { tool in
            let name = AgentFilterBarView.displayName(for: tool.id)
            let share = Double(tool.tokens) / Double(totalTokens) * 100
            let shareText = localization.localized(.distributionShare, arguments: share)
            return "\(name), \(TokenFormatter.formatFull(tool.tokens)) \(tokenUnit), \(shareText)"
        }.joined(separator: ", ")
    }

    // MARK: - Tool Row

    private func toolRow(name: String, tokens: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption)
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(tokens > 0 ? TokenFormatter.formatCompact(tokens) : "-")
                .font(.caption.monospacedDigit())
                .foregroundColor(tokens > 0 ? AppTheme.Text.secondary : AppTheme.Text.quaternary)
                .help(tokens > 0 ? "\(TokenFormatter.formatFull(tokens)) \(localization.localized(.tokenUnit))" : "")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(TokenFormatter.formatFull(tokens)) \(localization.localized(.tokenUnit))")
    }

    // MARK: - Update Banner

    private func updateBanner(_ release: UpdateRelease) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(AppTheme.Status.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: localization.localized(.updateAvailableTitle), release.version.description))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.Text.primary)
                Text(release.title)
                    .font(.caption2)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(release.title)
            }
            Spacer()
            Button(localization.localized(.downloadUpdate)) {
                NSWorkspace.shared.open(release.preferredAsset()?.downloadURL ?? release.pageURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(localization.localized(.downloadUpdate))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.Border.subtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Active Tools

    /// Tools with activity today, sorted by tokens descending. Zero-token and
    /// unknown tools are omitted so the popover never shows unused rows.
    public struct ActiveTool: Sendable, Equatable {
        public let id: String
        public let tokens: Int
    }

    public static func activeTools(for summary: TodaySummary?) -> [ActiveTool] {
        guard let summary else { return [] }
        return summary.toolTokens
            .filter { $0.value > 0 }
            .map { ActiveTool(id: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens || ($0.tokens == $1.tokens && $0.id < $1.id) }
    }
}

private struct SparkLine: Shape {
    let points: [TrendPoint]

    func path(in rect: CGRect) -> Path {
        let values = points.map { CGFloat(max(0, $0.tokens)) }
        guard values.count > 1 else { return Path() }
        let maxValue = max(values.max() ?? 0, 1)
        let denominator = CGFloat(max(values.count - 1, 1))
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) / denominator * rect.width
            let normalized = value / maxValue
            let y = rect.maxY - normalized * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

// MARK: - Quiet Hover Controls

private struct QuietIconButton: View {
    let systemName: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? AppTheme.Text.primary : AppTheme.Text.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? AppTheme.Surface.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

private struct QuietTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(isHovered ? AppTheme.Text.primary : AppTheme.Text.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? AppTheme.Surface.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    MenuBarPopoverView(
        model: StatusSummaryModel(summary: TodaySummary(
            totalTokens: 1_254_300,
            totalCostUSD: 3.42,
            toolTokens: ["claude": 800_000, "gemini": 454_300],
            toolCosts: ["claude": 2.10, "gemini": 1.32]
        )),
        onOpenDashboard: {},
        onSyncNow: {},
        onQuit: {}
    )
}
