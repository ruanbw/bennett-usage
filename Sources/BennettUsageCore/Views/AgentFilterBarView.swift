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
        default: return agent.capitalized
        }
    }

    public static func brandColor(for agent: String) -> Color {
        switch agent.lowercased() {
        case "pi": return Color(red: 0.06, green: 0.73, blue: 0.51)
        case "omp": return Color(red: 0.96, green: 0.62, blue: 0.04)
        case "claude": return Color(red: 0.91, green: 0.44, blue: 0.32)
        case "codex": return Color(red: 0.05, green: 0.65, blue: 0.91)
        default: return .purple
        }
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
                    let color = Self.brandColor(for: agent)

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
