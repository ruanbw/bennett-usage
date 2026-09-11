import SwiftUI

public struct MenuBarPopoverView: View {
    public let summary: TodaySummary?
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void
    public let onOpenSettings: (() -> Void)?
    @ObservedObject public var localization: LocalizationManager

    public init(
        summary: TodaySummary?,
        localization: LocalizationManager = .shared,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.summary = summary
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
                    Text("$\(String(format: "%.2f", summary?.totalCostUSD ?? 0.0))")
                        .font(.title2).bold().foregroundColor(.green)
                }
            }

            Divider()

            Text(localization.localized(.toolBreakdownToday))
                .font(.caption).bold().foregroundColor(.secondary)

            VStack(spacing: 6) {
                let toolColors = ChartPalette.shared.colors(for: ["omp", "pi", "claude", "codex", "gemini"])
                toolRow(name: "Oh My Pi", tokens: summary?.toolTokens["omp"] ?? 0, color: toolColors["omp"] ?? .gray)
                toolRow(name: "Pi Agent", tokens: summary?.toolTokens["pi"] ?? 0, color: toolColors["pi"] ?? .gray)
                toolRow(name: "Claude Code", tokens: summary?.toolTokens["claude"] ?? 0, color: toolColors["claude"] ?? .gray)
                toolRow(name: "OpenAI Codex", tokens: summary?.toolTokens["codex"] ?? 0, color: toolColors["codex"] ?? .gray)
                toolRow(name: "Gemini CLI", tokens: summary?.toolTokens["gemini"] ?? 0, color: toolColors["gemini"] ?? .gray)
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
        summary: TodaySummary(
            totalTokens: 1_254_300,
            totalCostUSD: 3.42,
            toolTokens: ["claude": 800_000, "gemini": 454_300],
            toolCosts: ["claude": 2.10, "gemini": 1.32]
        ),
        onOpenDashboard: {},
        onSyncNow: {},
        onQuit: {}
    )
}
