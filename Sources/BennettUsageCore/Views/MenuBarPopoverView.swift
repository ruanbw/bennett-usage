import SwiftUI
import AppKit

/// Shared summary state for the menu bar popover: the popover's hosting
/// controller is built once and stays alive; publishing a new summary here
/// refreshes the view in place instead of rebuilding the whole hierarchy.
@MainActor
public final class StatusSummaryModel: ObservableObject {
    @Published public var summary: TodaySummary?
    /// Database read timestamp retained for callers that need to distinguish a
    /// cached read from a source sync. It is deliberately not used as proof of
    /// a successful source refresh, and deliberately not `@Published`: no view
    /// reads it, so publishing it invalidated the popover's SwiftUI view graph —
    /// and re-ran its layout — on every completed read, for a value nothing
    /// displays.
    public var lastRefreshedAt: Date?
    /// Source-sync facts published by StatusItemController. A database read can
    /// succeed while every source sync is stale or failed, so presentation code
    /// must use this model for success/failure messaging.
    @Published public var freshness: SyncFreshnessModel
    @Published public var trendPoints: [TrendPoint]?
    public init(
        summary: TodaySummary? = nil,
        lastRefreshedAt: Date? = nil,
        trendPoints: [TrendPoint]? = nil,
        freshness: SyncFreshnessModel = .unknown
    ) {
        self.summary = summary
        self.lastRefreshedAt = lastRefreshedAt
        self.trendPoints = trendPoints
        self.freshness = freshness
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
    @AppStorage(AppThemeMode.storageKey) private var themeMode: AppThemeMode = .dark

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

        return VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider().overlay(AppTheme.Border.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    todayConclusion(active: active)
                    AppTheme.Border.divider.frame(height: AppTheme.Layout.hairline)

                    if let update = updateChecker.availableUpdate {
                        updateBanner(update)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                    } else {
                        updateStatusNotice
                    }

                    AppTheme.Border.divider.frame(height: AppTheme.Layout.hairline)
                        .padding(.top, updateChecker.availableUpdate == nil ? 14 : 0)
                    sourceBreakdown(active: active, toolColors: toolColors)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().overlay(AppTheme.Border.divider)
            actionBar
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.localized(.quickGlance))
        .preferredColorScheme(themeMode.colorScheme)
    }

    /// The popover hangs off a menu bar item that already names the app, so the
    /// header states the window's subject — today's usage — rather than
    /// repeating the product name, and carries the sync state inline. Freshness
    /// used to get its own tinted panel between the total and the breakdown,
    /// which cost a whole band to say one short thing.
    private var popoverHeader: some View {
        let isRefreshing = model.freshness.isRefreshing
        let hasFailure = model.freshness.partialFailure != nil
        let hasSuccessfulRefresh = model.freshness.hasSuccessfulRefresh
        let systemImage: String
        let color: Color
        if isRefreshing {
            systemImage = "arrow.triangle.2.circlepath"
            color = AppTheme.Chrome.glyphActive
        } else if hasFailure {
            systemImage = "exclamationmark.triangle.fill"
            color = AppTheme.Status.error
        } else if hasSuccessfulRefresh {
            systemImage = "checkmark.circle.fill"
            color = AppTheme.Status.success
        } else {
            systemImage = "clock.badge.exclamationmark"
            color = AppTheme.Text.tertiary
        }

        let detail = isRefreshing
            ? localization.localized(.syncInProgress)
            : hasFailure
                ? localization.localized(.syncFailed)
                : dataFreshnessText

        return HStack(spacing: 8) {
            SectionEyebrow(localization.localized(.todaysTokens))
            StatusMarker(systemImage: systemImage, text: detail, color: color)
            Spacer(minLength: 6)
            if let onOpenSettings = onOpenSettings {
                QuietIconButton(
                    systemName: "gearshape",
                    tooltip: localization.localized(.openSettingsAction),
                    action: onOpenSettings
                )
                .accessibilityLabel(localization.localized(.settings))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localization.localized(.popoverSyncStatus, arguments: detail))
        .help(detail)
    }

    private func todayConclusion(active: [ActiveTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary, summary.totalTokens > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(TokenFormatter.formatCompact(summary.totalTokens))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Text.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .help(TokenFormatter.formatWithTooltip(summary.totalTokens).tooltip)

                    Spacer(minLength: 8)

                    // Spend is a value, not a health state. Rendering it in the
                    // success green made a routine cost read as a status light
                    // and competed with the freshness marker for the same hue.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(localization.localized(.estimatedCost))
                            .font(AppTheme.Typography.caption)
                            .foregroundColor(AppTheme.Text.tertiary)
                        Text(pricingEngine.spendString(summary.totalCostUSD))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Text.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(localization.localized(.popoverAccessibilityDescription))
            } else {
                HStack(spacing: 9) {
                    Image(systemName: summary == nil ? "questionmark.circle" : "chart.bar")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Text.secondary)
                        .accessibilityHidden(true)
                    Text(summary == nil ? localization.localized(.noDataToDisplay) : localization.localized(.emptyUsage))
                        .font(.headline)
                        .foregroundColor(AppTheme.Text.primary)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if let points = model.trendPoints,
               summary?.totalTokens ?? 0 > 0,
               points.contains(where: { $0.tokens > 0 }),
               points.count > 1 {
                glanceTrend(points: points)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        VStack(spacing: 7) {
            Button(action: onOpenDashboard) {
                Label(localization.localized(.openDashboardAction), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 7) {
                Button(action: onSyncNow) {
                    Label(localization.localized(.syncNow), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(localization.localized(.syncNow))

                if let onOpenSettings = onOpenSettings {
                    Button(action: onOpenSettings) {
                        Label(localization.localized(.settings), systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(localization.localized(.settings))
                }
            }

            QuietTextButton(
                title: localization.localized(.quit),
                action: onQuit
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel(localization.localized(.quit))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var dataFreshnessText: String {
        guard let lastSuccessfulAt = model.freshness.lastSuccessful?.completedAt else {
            return localization.localized(.notSyncedYet)
        }
        let minutes = max(0, Int(Date().timeIntervalSince(lastSuccessfulAt) / 60))
        if minutes == 0 {
            return localization.localized(.dataUpdatedJustNow)
        }
        return localization.localized(.dataUpdatedMinutesAgo, arguments: minutes)
    }

    /// A sparkline with a baseline and a named peak. Without them the mark
    /// floated in its own whitespace and gave no scale, so "is this a spike or
    /// a plateau" was unanswerable from the glance it was meant to support.
    private func glanceTrend(points: [TrendPoint]) -> some View {
        let total = points.reduce(0) { $0 + $1.tokens }
        let peak = points.max { $0.tokens < $1.tokens }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localization.localized(.hourlyTrendToday))
                    .font(AppTheme.Typography.label)
                    .foregroundColor(AppTheme.Text.tertiary)
                Spacer(minLength: 6)
                if let peak, peak.tokens > 0 {
                    Text(localization.localized(.popoverPeakAt, arguments: peak.label))
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Text.quaternary)
                        .lineLimit(1)
                }
                Text(TokenFormatter.formatCompact(peak?.tokens ?? 0))
                    .font(AppTheme.Typography.tabular)
                    .foregroundColor(AppTheme.Text.secondary)
            }

            SparkLine(points: points)
                .fill(AppTheme.Data.series.opacity(0.28))
                .frame(height: 26)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppTheme.Data.track)
                        .frame(height: AppTheme.Layout.hairline)
                }
                .accessibilityLabel(localization.localized(.hourlyTrendToday))
                .accessibilityValue(TokenFormatter.formatFull(total))
        }
    }

    private func sourceBreakdown(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        let visibleTools = Array(active.prefix(3))
        let totalActive = active.reduce(0) { $0 + $1.tokens }

        return VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(localization.localized(.toolBreakdownToday))

            if visibleTools.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Text.tertiary)
                        .accessibilityHidden(true)
                    Text(localization.localized(.popoverNoUsage))
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Text.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                // Same neutral-track treatment as the Dashboard, so the two
                // surfaces read as one product rather than two bar styles.
                ProportionBar(
                    segments: active.map { tool in
                        ProportionBar.Segment(
                            id: tool.id,
                            share: totalActive > 0 ? Double(tool.tokens) / Double(totalActive) : 0,
                            color: toolColors[tool.id]
                                ?? AppTheme.Agent.knownColor(for: tool.id)
                                ?? AppTheme.Harmonic.color(for: tool.id)
                        )
                    },
                    height: 6
                )
                .accessibilityValue(
                    Self.distributionAccessibilityValue(for: active, localization: localization)
                )

                VStack(spacing: 0) {
                    ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 {
                            PanelDivider(inset: 15)
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(
                                    toolColors[tool.id]
                                        ?? AppTheme.Agent.knownColor(for: tool.id)
                                        ?? AppTheme.Harmonic.color(for: tool.id)
                                )
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(AgentFilterBarView.displayName(for: tool.id))
                                .font(AppTheme.Typography.rowTitle)
                                .foregroundColor(AppTheme.Text.primary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(TokenFormatter.formatCompact(tool.tokens))
                                .font(AppTheme.Typography.tabular)
                                .foregroundColor(AppTheme.Text.secondary)
                                .lineLimit(1)

                            Text(String(format: "%.1f%%", topShare(for: tool, in: active)))
                                .font(AppTheme.Typography.tabular)
                                .foregroundColor(AppTheme.Text.quaternary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .frame(height: 28)
                        .accessibilityElement(children: .combine)
                        .help(TokenFormatter.formatFull(tool.tokens))
                    }
                }

                if active.count > visibleTools.count {
                    Text(String(
                        format: localization.localized(.moreToolsCount),
                        active.count - visibleTools.count
                    ))
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.quaternary)
                    .padding(.top, 2)
                    .accessibilityLabel(
                        String(
                            format: localization.localized(.moreToolsCount),
                            active.count - visibleTools.count
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func topShare(for tool: ActiveTool, in active: [ActiveTool]) -> Double {
        let total = active.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return 0 }
        return Double(tool.tokens) / Double(total) * 100
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

    // MARK: - Update Banner

    @ViewBuilder
    private var updateStatusNotice: some View {
        switch updateChecker.status {
        case .checking:
            compactUpdateNotice(
                systemName: "arrow.triangle.2.circlepath",
                title: localization.localized(.checkingForUpdates),
                color: AppTheme.Status.accent
            )
        case .failed:
            compactUpdateNotice(
                systemName: "exclamationmark.triangle.fill",
                title: localization.localized(.updateCheckFailed),
                color: AppTheme.Status.error
            )
        default:
            EmptyView()
        }
    }

    private func compactUpdateNotice(systemName: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
    }

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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Status.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Status.accent.opacity(0.22), lineWidth: 0.5)
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
