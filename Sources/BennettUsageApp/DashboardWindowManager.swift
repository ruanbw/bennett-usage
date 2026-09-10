import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class DashboardWindowManager {
    public static let shared = DashboardWindowManager()
    private var window: NSWindow?

    public func show(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator, openSettings: Bool = false) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = DashboardView(aggregator: aggregator, showSettingsInitially: openSettings)
        let hostingController = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = LocalizationManager.shared.localized(.dashboardTitle)
        newWindow.contentViewController = hostingController
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
