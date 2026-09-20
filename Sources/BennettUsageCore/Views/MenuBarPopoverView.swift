import SwiftUI
import AppKit

/// Shared summary state for the menu bar popover: the popover's hosting
/// controller is built once and stays alive; publishing a new summary here
/// refreshes the view in place instead of rebuilding the whole hierarchy.
@MainActor
public final class StatusSummaryModel: ObservableObject {
    @Published public var summary: TodaySummary?
    public init(summary: TodaySummary? = nil) {
        self.summary = summary
    }
}

public struct MenuBarPopoverView: View {
    @ObservedObject public var model: StatusSummaryModel
    @ObservedObject public var updateChecker: UpdateChecker
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
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.model = model
        self.localization = localization
        self.updateChecker = updateChecker
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Row: App Title & Quiet Action Buttons
            HStack {
                Label(localization.localized(.appName), systemImage: "sparkles")
                    .font(.headline)
                    .foregroundColor(AppTheme.Text.primary)
                Spacer()
                if let onOpenSettings = onOpenSettings {
                    QuietIconButton(
                        systemName: "gearshape",
                        tooltip: localization.localized(.settings),
                        action: onOpenSettings
                    )
                }
                QuietIconButton(
                    systemName: "macwindow",
                    tooltip: localization.localized(.openDashboardShortcut),
                    action: onOpenDashboard
                )
            }

            // Today Metrics Row: Big Tokens & Estimated Spend
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.localized(.todaysTokens))
                        .font(.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                    Text(TokenFormatter.formatCompact(summary?.totalTokens ?? 0))
                        .font(.title2).bold()
                        .foregroundColor(AppTheme.Text.primary)
                        .help(TokenFormatter.formatWithTooltip(summary?.totalTokens ?? 0).tooltip)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(localization.localized(.estimatedCost))
                        .font(.caption)
                        .foregroundColor(AppTheme.Text.secondary)
                    Text(PricingEngine.shared.spendString(summary?.totalCostUSD ?? 0.0))
                        .font(.title2).bold()
                        .foregroundColor(AppTheme.Status.success)
                }
            }
            .padding(.top, 2)

            let active = Self.activeTools(for: summary)
            let toolColors = ChartPalette.shared.colors(for: active.map(\.id))

            // Mini Distribution Bar: 4pt continuous multi-segment capsule
            miniDistributionBar(active: active, toolColors: toolColors)
                .padding(.vertical, 2)

            // Micro Tool Breakdown Rows
            VStack(alignment: .leading, spacing: 6) {
                Text(localization.localized(.toolBreakdownToday))
                    .font(.caption.weight(.medium))
                    .foregroundColor(AppTheme.Text.secondary)

                if active.isEmpty {
                    Text(localization.localized(.noToolsActiveToday))
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Text.tertiary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(active, id: \.id) { tool in
                        toolRow(
                            name: AgentFilterBarView.displayName(for: tool.id),
                            tokens: tool.tokens,
                            color: toolColors[tool.id] ?? AppTheme.Agent.knownColor(for: tool.id) ?? AppTheme.Harmonic.color(for: tool.id)
                        )
                    }
                }
            }

            // Update Banner (if available)
            if let update = updateChecker.availableUpdate {
                updateBanner(update)
                    .padding(.top, 2)
            }

            // Footer: Subtle Sync Now & Quiet Quit
            HStack {
                Button(action: onSyncNow) {
                    Text(localization.localized(.syncNow))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                QuietTextButton(
                    title: localization.localized(.quit),
                    action: onQuit
                )
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial)
    }

    // MARK: - Mini Distribution Bar

    private func miniDistributionBar(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        let totalActive = active.reduce(0) { $0 + $1.tokens }
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
    }

    // MARK: - Tool Row

    private func toolRow(name: String, tokens: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.subheadline)
                .foregroundColor(AppTheme.Text.primary)
            Spacer()
            Text(tokens > 0 ? TokenFormatter.formatCompact(tokens) : "-")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(tokens > 0 ? AppTheme.Text.secondary : AppTheme.Text.quaternary)
                .help(tokens > 0 ? "\(TokenFormatter.formatFull(tokens)) tokens" : "")
        }
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
