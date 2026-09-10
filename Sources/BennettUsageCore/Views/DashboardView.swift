import SwiftUI

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager
    @State private var selectedItem: NavigationItem
    @State private var agentCount: Int = 0
    @State private var isSyncing: Bool = false
    @State private var lastSyncDate: Date? = nil

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared,
        showSettingsInitially: Bool = false
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self._selectedItem = State(initialValue: showSettingsInitially ? .settings : .dashboard)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedItem: $selectedItem,
                agentCount: agentCount,
                isSyncing: isSyncing,
                lastSyncDate: lastSyncDate,
                onSyncNow: { Task { await performSync() } },
                localization: localization
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            switch selectedItem {
            case .dashboard:
                DashboardContentView(aggregator: aggregator, localization: localization)
            case .settings:
                SettingsContentView(aggregator: aggregator, localization: localization)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .task {
            await loadAgentHealth()
        }
    }

    private func loadAgentHealth() async {
        let infos = (try? await aggregator.fetchAgentHealthInfos()) ?? []
        agentCount = infos.filter(\.isInstalled).count
        lastSyncDate = Date()
    }

    private func performSync() async {
        isSyncing = true
        await loadAgentHealth()
        isSyncing = false
    }
}
