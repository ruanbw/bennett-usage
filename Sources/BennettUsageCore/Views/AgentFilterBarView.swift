import SwiftUI

public struct AgentFilterBarView: View {
    public let selectedAgent: String?
    public let availableAgents: [String]
    public let localization: LocalizationManager
    public let onSelect: (String?) -> Void

    public init(
        selectedAgent: String?,
        availableAgents: [String],
        localization: LocalizationManager = .shared,
        onSelect: @escaping (String?) -> Void
    ) {
        self.selectedAgent = selectedAgent
        self.availableAgents = availableAgents
        self.localization = localization
        self.onSelect = onSelect
    }

    /// Display name per agent source id. This table is the single source of
    /// truth for the agent universe: the fixed palette below derives from it, so
    /// an agent can never get a color without also having a display name.
    public static let displayNamesById: [String: String] = [
        "pi": "Pi Agent",
        "omp": "Oh My Pi",
        "claude": "Claude Code",
        "codex": "OpenAI Codex",
        "continue": "Continue CLI",
        "gemini": "Gemini CLI",
        "antigravity": "Antigravity",
        "opencode": "OpenCode",
        "roo": "Roo Code · Cline",
        "cline": "Cline",
        "qwen": "Qwen Code",
        "copilot": "GitHub Copilot",
        "cursor": "Cursor",
        "trae": "Trae",
        "dsh": "DSH Harness",
        "goose": "Goose",
        "crush": "Crush",
        "kimi": "Kimi Code"
    ]

    /// Every agent id this app can record.
    public static let knownAgentIds: [String] = displayNamesById.keys.sorted()

    /// One color per agent, keyed by the whole agent universe rather than by the
    /// subset currently on screen. The pill list is scoped to the selected time
    /// range and therefore grows and shrinks as ranges are switched; assigning
    /// colors over a fixed universe keeps an agent's color identical in the
    /// pills, the tool donut and the heatmap day breakdown no matter which
    /// range — or which filter — is active.
    public static var colorMap: [String: Color] {
        ChartPalette.shared.colors(for: knownAgentIds)
    }

    public static func displayName(for agent: String) -> String {
        displayNamesById[agent.lowercased()] ?? agent.capitalized
    }


    private var isAllSelected: Bool {
        selectedAgent == nil
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                ForEach(availableAgents, id: \.self) { agent in
                    filterPill(
                        title: Self.displayName(for: agent),
                        color: Self.colorMap[agent.lowercased()] ?? AppTheme.Harmonic.color(for: agent),
                        isSelected: selectedAgent?.lowercased() == agent.lowercased()
                    ) {
                        onSelect(agent)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(availableAgents, id: \.self) { agent in
                        filterPill(
                            title: Self.displayName(for: agent),
                            color: Self.colorMap[agent.lowercased()] ?? AppTheme.Harmonic.color(for: agent),
                            isSelected: selectedAgent?.lowercased() == agent.lowercased()
                        ) {
                            onSelect(agent)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .accessibilityLabel(localization.localized(.filterAllAgents))
    }

    private func filterPill(
        title: String,
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AppTheme.Surface.selected : AppTheme.Surface.subtle.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.42) : AppTheme.Border.subtle, lineWidth: AppTheme.Layout.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
