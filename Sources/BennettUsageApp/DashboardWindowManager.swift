import AppKit
import SwiftUI
import BennettUsageCore

/// Owns the independent Settings window.
///
/// Settings is intentionally not a sheet owned by `DashboardWindowManager`:
/// dismissing it must leave the Dashboard window and its state untouched. The
/// 750 × 510 content size matches the existing settings surface while the
/// native title bar and close button provide the normal macOS window lifecycle.
@MainActor
public final class SettingsWindowManager: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowManager()

    public static let contentSize = NSSize(width: 750, height: 510)

    private var window: NSWindow?
    private var isClosingWindow = false

    public func show(
        aggregator: MetricsAggregator,
        localization: LocalizationManager = .shared
    ) {
        if let existingWindow = window {
            if isClosingWindow {
                // A close animation can still report the old window as visible.
                // Detach it so its late delegate callback cannot clear a fresh
                // Settings window created below.
                existingWindow.delegate = nil
                existingWindow.contentViewController = nil
                existingWindow.close()
                window = nil
                isClosingWindow = false
            } else {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        let view = SettingsSheetView(
            aggregator: aggregator,
            localization: localization,
            onDismiss: { [weak self] in self?.close() }
        )
        let hostingController = NSHostingController(rootView: view)
        // The native window owns sizing; otherwise SwiftUI's intrinsic size can
        // race the requested minimum and make the first presentation jump.
        hostingController.sizingOptions = []

        let newWindow = NSWindow(
            contentRect: NSRect(
                x: 120,
                y: 120,
                width: Self.contentSize.width,
                height: Self.contentSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = localization.localized(.settings)
        newWindow.contentViewController = hostingController
        newWindow.minSize = Self.contentSize
        newWindow.setContentSize(Self.contentSize)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.identifier = NSUserInterfaceItemIdentifier("BennettUsage.Settings")
        newWindow.delegate = self
        window = newWindow
        isClosingWindow = false

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.performClose(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        isClosingWindow = true
        closingWindow.delegate = nil
        closingWindow.contentViewController = nil
        window = nil
    }
}

/// Owns the standalone Dashboard window and its legacy settings entry point.
@MainActor
public final class DashboardWindowManager: NSObject, NSWindowDelegate {
    public static let shared = DashboardWindowManager()

    /// The approved content size used when a dashboard is first presented.
    public static let defaultContentSize = NSSize(width: 1080, height: 740)
    /// The smallest useful content size; the Dashboard view uses the same
    /// minimum so a user cannot shrink the native window into a broken layout.
    public static let minimumContentSize = NSSize(width: 960, height: 680)

    private var window: NSWindow?
    private var isClosingWindow = false
    private let presentation = DashboardPresentationState()

    public func show(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator, openSettings: Bool = false) {
        // Keep the existing public API source-compatible. Settings now opens in
        // its independent window; the Dashboard window is not created, hidden,
        // or reset by a Settings request.
        if openSettings {
            SettingsWindowManager.shared.show(aggregator: aggregator)
            return
        }

        // Throttled UI sync: opening the dashboard is frequent and must not pay
        // for a full-tree walk every time (U-01). If rows are actually inserted,
        // SyncCoordinator itself posts .bennettUsageDataDidUpdate, so no extra
        // post is needed here (see note below).
        Task {
            _ = try? await syncCoordinator.syncForUI()
        }

        if let existingWindow = window {
            // A close callback can lag behind the close animation. Do not revive
            // an instance that is already being torn down.
            if !isClosingWindow && (existingWindow.isVisible || existingWindow.isMiniaturized) {
                if existingWindow.isMiniaturized {
                    existingWindow.deminiaturize(nil)
                }
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // No manual .bennettUsageDataDidUpdate here: SyncCoordinator
                // already posts it on real inserts, and DashboardContentView
                // observes it via `.onReceive` + `loadDataThrottled()`.
                return
            }

            existingWindow.delegate = nil
            existingWindow.contentViewController = nil
            existingWindow.close()
            window = nil
        }

        let view = DashboardView(
            aggregator: aggregator,
            presentation: presentation,
            showSettingsInitially: false,
            onOpenSettings: {
                SettingsWindowManager.shared.show(aggregator: aggregator)
            }
        )
        let hostingController = NSHostingController(rootView: view)
        // The window owns the sizing contract. Letting the hosting controller
        // also propose a size makes the first layout race with `minSize` and
        // can produce a window that is too small on slower machines.
        hostingController.sizingOptions = []

        let newWindow = NSWindow(
            contentRect: NSRect(
                x: 100,
                y: 100,
                width: Self.defaultContentSize.width,
                height: Self.defaultContentSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = LocalizationManager.shared.localized(.dashboardTitle)
        newWindow.contentViewController = hostingController
        newWindow.minSize = Self.minimumContentSize
        newWindow.setContentSize(Self.defaultContentSize)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.identifier = NSUserInterfaceItemIdentifier("BennettUsage.Dashboard")
        newWindow.delegate = self
        self.window = newWindow
        isClosingWindow = false

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Compatibility entry point retained for callers that used the old
    /// `openSettings` argument. It now follows the independent Settings window
    /// path instead of mutating Dashboard presentation state.
    public func showSettings(aggregator: MetricsAggregator, syncCoordinator: SyncCoordinator) {
        SettingsWindowManager.shared.show(aggregator: aggregator)
    }

    /// Close the standalone window through the same delegate path as the close
    /// button. The app remains a menu-bar accessory after the last window goes
    /// away; a later Dashboard request builds a new window.
    public func close() {
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    /// Dropping the only strong reference on close tears down the hosting
    /// controller and its SwiftUI tree, cancelling the view's `.task`
    /// lifecycles (autoRefreshLoop) and notification subscriptions with it.
    /// Reopening goes through `show(...)` and builds a fresh window.
    public func windowWillClose(_ notification: Notification) {
        // A close notification can be delivered after a caller has already
        // created a replacement window. Never let that stale notification
        // clear the replacement or its settings state.
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        isClosingWindow = true
        closingWindow.delegate = nil
        // Explicitly release the controller as soon as the close begins. This
        // is important for the SwiftUI `.task`/notification lifecycles even on
        // AppKit versions that keep a closed window around internally.
        closingWindow.contentViewController = nil
        window = nil
    }
}
