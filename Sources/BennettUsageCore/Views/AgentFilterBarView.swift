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
        "gemini": "Gemini CLI",
        "antigravity": "Antigravity",
        "opencode": "OpenCode",
        "roo": "Roo Code · Cline",
        "cline": "Cline",
        "qwen": "Qwen Code",
        "copilot": "GitHub Copilot",
        "cursor": "Cursor",
        "trae": "Trae",
        "dsh": "DSH Harness"
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All Agents" pill
                Button {
                    onSelect(nil)
                } label: {
                    Text(localization.localized(.filterAllAgents))
                        .font(.caption)
                        .fontWeight(isAllSelected ? .semibold : .regular)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isAllSelected ? AppTheme.Status.accent.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isAllSelected ? AppTheme.Status.accent : AppTheme.Border.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Individual agent pills
                ForEach(availableAgents, id: \.self) { agent in
                    let isSelected = selectedAgent?.lowercased() == agent.lowercased()
                    let color = Self.colorMap[agent] ?? .gray

                    Button {
                        onSelect(agent)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(color)
                                .frame(width: 8, height: 8)
                            Text(Self.displayName(for: agent))
                                .font(.caption)
                                .fontWeight(isSelected ? .semibold : .regular)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isSelected ? color.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? color : AppTheme.Border.divider, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
