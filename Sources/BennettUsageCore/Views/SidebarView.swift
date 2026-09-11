import SwiftUI

public enum NavigationItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case settings

    public var id: String { rawValue }
}

public struct SidebarView: View {
    @Binding public var selectedItem: NavigationItem
    public let agentCount: Int
    public let isSyncing: Bool
    public let lastSyncDate: Date?
    public let onSyncNow: () -> Void
    public let localization: LocalizationManager

    public init(
        selectedItem: Binding<NavigationItem>,
        agentCount: Int = 0,
        isSyncing: Bool = false,
        lastSyncDate: Date? = nil,
        onSyncNow: @escaping () -> Void = {},
        localization: LocalizationManager = .shared
    ) {
        self._selectedItem = selectedItem
        self.agentCount = agentCount
        self.isSyncing = isSyncing
        self.lastSyncDate = lastSyncDate
        self.onSyncNow = onSyncNow
        self.localization = localization
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Brand Header
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis.ascending")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("Bennett Usage")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text("Token Analytics")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Navigation Items
            List(selection: $selectedItem) {
                Label(localization.localized(.navDashboard), systemImage: "chart.xyaxis.line")
                    .tag(NavigationItem.dashboard)
                Label(localization.localized(.navSettings), systemImage: "gearshape")
                    .tag(NavigationItem.settings)
            }
            .listStyle(.sidebar)

            Spacer()

            Divider()

            // Bottom Status Card
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(agentCount > 0 ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(localization.localized(.agentsConnected, arguments: agentCount))
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                if let date = lastSyncDate {
                    Text(syncStatusText(date: date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button {
                    onSyncNow()
                } label: {
                    HStack(spacing: 4) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                        }
                        Text(localization.localized(.rescanNow))
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(isSyncing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 210)
    }

    private func syncStatusText(date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return localization.localized(.syncedJustNow)
        }
        let minutes = Int(interval / 60)
        return localization.localized(.syncedMinutesAgo, arguments: minutes)
    }
}

#Preview {
    SidebarView(
        selectedItem: .constant(.dashboard),
        agentCount: 4,
        isSyncing: false,
        lastSyncDate: Date(),
        onSyncNow: {},
        localization: .shared
    )
    .frame(width: 220, height: 600)
}
