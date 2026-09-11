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

    public static func displayName(for agent: String) -> String {
        switch agent.lowercased() {
        case "pi": return "Pi Agent"
        case "omp": return "Oh My Pi"
        case "claude": return "Claude Code"
        case "codex": return "OpenAI Codex"
        case "gemini": return "Gemini CLI"
        default: return agent.capitalized
        }
    }


    private var isAllSelected: Bool {
        selectedAgent == nil
    }
    private var agentColors: [String: Color] {
        ChartPalette.shared.colors(for: availableAgents)
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
                                .fill(isAllSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isAllSelected ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Individual agent pills
                ForEach(availableAgents, id: \.self) { agent in
                    let isSelected = selectedAgent?.lowercased() == agent.lowercased()
                    let color = agentColors[agent] ?? .gray

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
                                .fill(isSelected ? color.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? color : Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
