import SwiftUI
import AppKit

public struct SettingsSheetView: View {
    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    public let initialCategory: SettingsCategory
    public let onDismiss: () -> Void
    @AppStorage(AppThemeMode.storageKey)
    private var themeModeRaw: String = AppThemeMode.dark.rawValue

    public init(
        aggregator: MetricsAggregator? = nil,
        localization: LocalizationManager = .shared,
        initialCategory: SettingsCategory = .general,
        onDismiss: @escaping () -> Void
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.initialCategory = initialCategory
        self.onDismiss = onDismiss
    }

    public var body: some View {
        SettingsContentView(
            aggregator: aggregator,
            localization: localization,
            initialCategory: initialCategory,
            onDismiss: onDismiss
        )
        .preferredColorScheme(AppThemeMode(rawValue: themeModeRaw)?.colorScheme)
        .frame(
            minWidth: 750,
            idealWidth: 750,
            maxWidth: .infinity,
            minHeight: 510,
            idealHeight: 510,
            maxHeight: .infinity
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Canvas.background)
    }
}
