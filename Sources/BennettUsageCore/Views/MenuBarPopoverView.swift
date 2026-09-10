import SwiftUI

public struct MenuBarPopoverView: View {
    public let summary: TodaySummary?
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void

    public init(
        summary: TodaySummary?,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.summary = summary
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bennett Usage", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button(action: onOpenDashboard) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Open Dashboard (⌘D)")
            }

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Today's Tokens").font(.caption).foregroundColor(.secondary)
                    Text("\((summary?.totalTokens ?? 0).formatted())")
                        .font(.title2).bold()
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Estimated Cost").font(.caption).foregroundColor(.secondary)
                    Text("$\(String(format: "%.2f", summary?.totalCostUSD ?? 0.0))")
                        .font(.title2).bold().foregroundColor(.green)
                }
            }

            Divider()

            Text("Tool Breakdown (Today)")
                .font(.caption).bold().foregroundColor(.secondary)

            VStack(spacing: 6) {
                toolRow(name: "Oh My Pi", tokens: summary?.toolTokens["omp"] ?? 0, color: .blue)
                toolRow(name: "Pi Agent", tokens: summary?.toolTokens["pi"] ?? 0, color: .green)
                toolRow(name: "Claude Code", tokens: summary?.toolTokens["claude"] ?? 0, color: .orange)
                toolRow(name: "OpenAI Codex", tokens: summary?.toolTokens["codex"] ?? 0, color: .teal)
            }

            Divider()

            HStack {
                Button("Sync Now", action: onSyncNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Quit", action: onQuit)
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
            Text(tokens > 0 ? tokens.formatted() : "-")
                .font(.subheadline)
                .foregroundColor(tokens > 0 ? .primary : .secondary)
        }
    }
}
