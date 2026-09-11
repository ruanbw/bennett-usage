import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class DashboardWindowManager {
    public static let shared = DashboardWindowManager()
    private var window: NSWindow?
    private let presentation = DashboardPresentationState()

    public func show(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator, openSettings: Bool = false) {
        Task {
            _ = try? await syncCoordinator.syncAll()
        }

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if openSettings {
                presentation.isShowingSettings = true
            }
            NotificationCenter.default.post(name: .bennettUsageDataDidUpdate, object: nil)
            return
        }
        let view = DashboardView(aggregator: aggregator, presentation: presentation, showSettingsInitially: openSettings)
        let hostingController = NSHostingController(rootView: view)
        hostingController.sizingOptions = []

        let newWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = LocalizationManager.shared.localized(.dashboardTitle)
        newWindow.contentViewController = hostingController
        newWindow.minSize = NSSize(width: 960, height: 680)
        newWindow.setContentSize(NSSize(width: 1080, height: 740))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
