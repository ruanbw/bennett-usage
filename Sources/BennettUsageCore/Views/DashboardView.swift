import SwiftUI

/// Shared presentation state for the dashboard window, owned by
/// `DashboardWindowManager` so external triggers (e.g. the status item's
/// settings shortcut) can open the settings sheet on an already-existing window.
public final class DashboardPresentationState: ObservableObject {
    @Published public var isShowingSettings: Bool

    public init(isShowingSettings: Bool = false) {
        self.isShowingSettings = isShowingSettings
    }
}

public struct DashboardView: View {
    public let aggregator: MetricsAggregator
    @ObservedObject public var localization: LocalizationManager
    @ObservedObject private var presentation: DashboardPresentationState

    public init(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared,
        presentation: DashboardPresentationState = DashboardPresentationState(),
        showSettingsInitially: Bool = false
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.presentation = presentation
        presentation.isShowingSettings = showSettingsInitially
    }

    public var body: some View {
        DashboardContentView(
            aggregator: aggregator,
            localization: localization,
            onOpenSettings: { presentation.isShowingSettings = true }
        )
        .frame(minWidth: 960, minHeight: 680)
        .sheet(isPresented: $presentation.isShowingSettings) {
            SettingsSheetView(
                aggregator: aggregator,
                localization: localization,
                onDismiss: { presentation.isShowingSettings = false }
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
