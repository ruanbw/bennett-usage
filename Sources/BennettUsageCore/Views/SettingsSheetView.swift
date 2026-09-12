import SwiftUI
import AppKit

public struct SettingsSheetView: View {
    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    public let initialCategory: SettingsCategory
    public let onDismiss: () -> Void

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
        .frame(width: 750, height: 510)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
