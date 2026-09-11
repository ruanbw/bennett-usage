import SwiftUI

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager
    @State private var isShowingSettings: Bool

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared,
        showSettingsInitially: Bool = false
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self._isShowingSettings = State(initialValue: showSettingsInitially)
    }

    public var body: some View {
        DashboardContentView(
            aggregator: aggregator,
            localization: localization,
            onOpenSettings: { isShowingSettings = true }
        )
        .frame(minWidth: 960, minHeight: 680)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheetView(
                aggregator: aggregator,
                localization: localization,
                onDismiss: { isShowingSettings = false }
            )
        }
    }
}

#Preview {
    let db = try! DatabaseManager.inMemory()
    let aggregator = MetricsAggregator(database: db)
    return DashboardView(aggregator: aggregator)
        .frame(width: 1060, height: 720)
}
