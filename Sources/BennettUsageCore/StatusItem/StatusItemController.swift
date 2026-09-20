import AppKit
import Combine
import SwiftUI

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    // Only touched on the main actor (setup + deinit); `nonisolated(unsafe)`
    // keeps it reachable from the nonisolated `deinit` that removes it.
    nonisolated(unsafe) private var outsideClickMonitor: Any?
    private let aggregator: MetricsAggregator
    private let syncCoordinator: SyncCoordinator
    private let summaryModel = StatusSummaryModel()
    private let updateChecker: UpdateChecker
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void
    private let localization: LocalizationManager
    private var refreshTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var updateObservation: AnyCancellable?

    public init(
        aggregator: MetricsAggregator,
        syncCoordinator: SyncCoordinator,
        localization: LocalizationManager = .shared,
        updateChecker: UpdateChecker = .shared,
        heartbeatInterval: TimeInterval? = 30.0,
        openDashboardAction: @escaping () -> Void = {},
        openSettingsAction: @escaping () -> Void = {}
    ) {
        self.aggregator = aggregator
        self.syncCoordinator = syncCoordinator
        self.localization = localization
        self.updateChecker = updateChecker
        self.openDashboardAction = openDashboardAction
        self.openSettingsAction = openSettingsAction
        super.init()
        setupStatusItem()
        setupPopover()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataDidUpdate),
            name: .bennettUsageDataDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDayChanged),
            name: .NSCalendarDayChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // A background check can land long after launch; the menu bar icon is
        // the only surface a popover-shy user ever looks at.
        updateObservation = updateChecker.$status
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyStatusItemAppearance() }
            }
        refreshData()

        if let heartbeatInterval, heartbeatInterval > 0 {
            heartbeatTask = Task { [weak self, syncCoordinator] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    _ = try? await syncCoordinator.syncForUI(minInterval: 10)
                    guard !Task.isCancelled, let self else { break }
                    self.refreshData()
                }
            }
        }
    }

    deinit {
        heartbeatTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    @objc private func handleDataDidUpdate() {
        refreshData()
    }

    @objc private func handleDayChanged() {
        refreshData()
    }

    @objc private func handleSystemDidWake() {
        Task { [weak self] in
            _ = try? await self?.syncCoordinator.syncForUI(force: true)
            self?.refreshData()
        }
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: localization.localized(.statusItemAccessibility))
            button.toolTip = localization.localized(.statusItemAccessibility)
            button.target = self
            button.action = #selector(togglePopover)
        }
    }
    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        // Built once; publishing a new `summaryModel.summary` refreshes the
        // view in place instead of rebuilding the hosting controller.
        let view = MenuBarPopoverView(
            model: summaryModel,
            localization: localization,
            updateChecker: updateChecker,
            onOpenDashboard: { [weak self] in self?.openDashboardWindow() },
            onSyncNow: { [weak self] in self?.forceSync() },
            onQuit: { NSApp.terminate(nil) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        sizePopoverToContent()
        // `.transient` only auto-dismisses while the popover owns key focus; a
        // status-item click leaves the app inactive, so outside clicks have to
        // close it explicitly. Global monitors never see events delivered to
        // this app, so clicking the status item still toggles via its action.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    /// AppKit anchors the popover using `contentSize`, while the hosting
    /// controller resizes the popover window to the SwiftUI content's fitting
    /// size. A hard-coded `contentSize` therefore anchors it for the wrong
    /// height, leaving the panel detached from the icon or pushed over the menu
    /// bar. Keep `contentSize` in sync with the content it will present.
    private func sizePopoverToContent() {
        guard let contentView = popover.contentViewController?.view else { return }
        let fittingSize = contentView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }
        popover.contentSize = fittingSize
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sizePopoverToContent()
            // Show immediately with the cached summary; refresh runs async.
            // Opening the popover is frequent and must not run a full-tree sync
            // every click (U-01), so this path uses the throttled UI sync. The
            // refresh below runs unconditionally after it, so a throttled pass
            // still re-reads (a concurrent FSEvents sync may have inserted).
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            refreshData()
            Task {
                _ = try? await syncCoordinator.syncForUI()
                // `syncForUI` is throttled and only posts a notification when
                // it actually inserts rows; always re-read afterwards so a
                // throttled pass (or a concurrent FSEvents sync) still leaves
                // the popover showing fresh data instead of the stale cache.
                refreshData()
            }
        }
    }

    public func refreshData() {
        // Latest-wins: overlapping notifications used to race and a slow
        // earlier fetch could overwrite a fresher summary. Cancel the
        // in-flight read so only the newest request publishes.
        refreshTask?.cancel()
        let aggregator = self.aggregator
        refreshTask = Task {
            let summary = await Task.detached(priority: .userInitiated) { () -> TodaySummary? in
                if let res = try? await aggregator.fetchTodaySummary() {
                    return res
                }
                // Retry once after brief yield in case database was locked during transaction
                try? await Task.sleep(nanoseconds: 100_000_000)
                return try? await aggregator.fetchTodaySummary()
            }.value

            guard !Task.isCancelled, let summary else { return }
            summaryModel.summary = summary
            applyStatusItemAppearance()
        }
    }

    /// Renders the status item from the current summary + update state. Called
    /// both when data lands and when the update checker changes, so the two
    /// sources never overwrite each other's contribution to the icon/tooltip.
    private func applyStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let tokens = summaryModel.summary?.totalTokens ?? 0
        button.title = TokenFormatter.formatStatusTitle(tokens)
        var tooltip = tokens > 0
            ? "\(TokenFormatter.formatFull(tokens)) tokens"
            : localization.localized(.statusItemAccessibility)

        if let update = updateChecker.availableUpdate {
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: String(
                    format: localization.localized(.updateAvailableTitle),
                    update.version.description
                )
            )
            tooltip += " · " + String(format: localization.localized(.updateAvailableTitle), update.version.description)
        } else {
            button.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: localization.localized(.statusItemAccessibility)
            )
        }
        button.toolTip = tooltip
    }

    /// Explicit user-initiated sync (the popover’s “Sync Now” button).
    /// `force: true` bypasses the UI throttle so a deliberate refresh is never
    /// swallowed, then the summary is refreshed.
    public func forceSync() {
        Task {
            _ = try? await syncCoordinator.syncForUI(force: true)
            refreshData()
        }
    }

    private func openDashboardWindow() {
        popover.performClose(nil)
        openDashboardAction()
    }

    private func openSettings() {
        popover.performClose(nil)
        openSettingsAction()
    }
}
