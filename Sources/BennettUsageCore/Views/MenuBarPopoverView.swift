import SwiftUI

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
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void
    public let onOpenSettings: (() -> Void)?
    @ObservedObject public var localization: LocalizationManager

    public var summary: TodaySummary? { model.summary }

    public init(
        model: StatusSummaryModel,
        localization: LocalizationManager = .shared,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.model = model
        self.localization = localization
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localization.localized(.appName), systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if let onOpenSettings = onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help(localization.localized(.settings))
                }
                Button(action: onOpenDashboard) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help(localization.localized(.openDashboardShortcut))
            }

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text(localization.localized(.todaysTokens)).font(.caption).foregroundColor(.secondary)
                    Text(TokenFormatter.formatCompact(summary?.totalTokens ?? 0))
                        .font(.title2).bold()
                        .help(TokenFormatter.formatWithTooltip(summary?.totalTokens ?? 0).tooltip)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(localization.localized(.estimatedCost)).font(.caption).foregroundColor(.secondary)
                    Text(PricingEngine.shared.spendString(summary?.totalCostUSD ?? 0.0))
                        .font(.title2).bold().foregroundColor(.green)
                }
            }

            Divider()

            Text(localization.localized(.toolBreakdownToday))
                .font(.caption).bold().foregroundColor(.secondary)

            VStack(spacing: 6) {
                let active = Self.activeTools(for: summary)
                if active.isEmpty {
                    Text(localization.localized(.noToolsActiveToday))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    let toolColors = ChartPalette.shared.colors(for: active.map(\.id))
                    ForEach(active, id: \.id) { tool in
                        toolRow(name: AgentFilterBarView.displayName(for: tool.id), tokens: tool.tokens, color: toolColors[tool.id] ?? .gray)
                    }
                }
            }

            Divider()

            HStack {
                Button(localization.localized(.syncNow), action: onSyncNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button(localization.localized(.quit), action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
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

    private func toolRow(name: String, tokens: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.subheadline)
            Spacer()
            Text(tokens > 0 ? TokenFormatter.formatCompact(tokens) : "-")
                .font(.subheadline)
                .foregroundColor(tokens > 0 ? .primary : .secondary)
                .help(tokens > 0 ? "\(TokenFormatter.formatFull(tokens)) tokens" : "")
        }
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
