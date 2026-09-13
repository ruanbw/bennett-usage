import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class DashboardWindowManager: NSObject, NSWindowDelegate {
    public static let shared = DashboardWindowManager()
    private var window: NSWindow?
    private let presentation = DashboardPresentationState()

    public func show(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator, openSettings: Bool = false) {
        // Throttled UI sync: opening the dashboard is frequent and must not pay
        // for a full-tree walk every time (U-01). If rows are actually inserted,
        // SyncCoordinator itself posts .bennettUsageDataDidUpdate, so no extra
        // post is needed here (see note below).
        Task {
            _ = try? await syncCoordinator.syncForUI()
        }

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if openSettings {
                presentation.isShowingSettings = true
            }
            // No manual .bennettUsageDataDidUpdate here: SyncCoordinator already
            // posts it on real inserts, and DashboardContentView observes it via
            // `.onReceive` + `loadDataThrottled()`. Posting unconditionally also
            // forced a ~194 ms recompute even when the throttled sync changed
            // nothing (U-01/U-12).
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
        newWindow.delegate = self
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    /// Dropping the only strong reference on close tears down the hosting
    /// controller and its SwiftUI tree, cancelling the view's `.task`
    /// lifecycles (autoRefreshLoop) and notification subscriptions with it.
    /// Reopening goes through `show(...)` and builds a fresh window.
    public func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        presentation.isShowingSettings = false
    }
}
