import SwiftUI
import AppKit

public struct SettingsSheetView: View {
    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    public let onDismiss: () -> Void

    public init(
        aggregator: MetricsAggregator? = nil,
        localization: LocalizationManager = .shared,
        onDismiss: @escaping () -> Void
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.onDismiss = onDismiss
    }

    public var body: some View {
        SettingsContentView(
            aggregator: aggregator,
            localization: localization,
            onDismiss: onDismiss
        )
        .frame(width: 620, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
