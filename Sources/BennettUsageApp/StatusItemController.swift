import AppKit
import SwiftUI
import BennettUsageCore

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let aggregator: MetricsAggregator
    private let syncCoordinator: SyncCoordinator
    private let summaryModel = StatusSummaryModel()
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void
    private let localization: LocalizationManager

    public init(
        aggregator: MetricsAggregator,
        syncCoordinator: SyncCoordinator,
        localization: LocalizationManager = .shared,
        openDashboardAction: @escaping () -> Void = {},
        openSettingsAction: @escaping () -> Void = {}
    ) {
        self.aggregator = aggregator
        self.syncCoordinator = syncCoordinator
        self.localization = localization
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
        refreshData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleDataDidUpdate() {
        refreshData()
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
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.behavior = .transient
        // Built once; publishing a new `summaryModel.summary` refreshes the
        // view in place instead of rebuilding the hosting controller.
        let view = MenuBarPopoverView(
            model: summaryModel,
            localization: localization,
            onOpenDashboard: { [weak self] in self?.openDashboardWindow() },
            onSyncNow: { [weak self] in self?.forceSync() },
            onQuit: { NSApp.terminate(nil) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Show immediately with the cached summary; sync + refresh run async.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            refreshData()
            forceSync()
        }
    }

    public func refreshData() {
        Task {
            if let summary = try? await aggregator.fetchTodaySummary() {
                summaryModel.summary = summary
                if let button = self.statusItem.button {
                    button.title = TokenFormatter.formatStatusTitle(summary.totalTokens)
                    button.toolTip = summary.totalTokens > 0
                        ? "\(TokenFormatter.formatFull(summary.totalTokens)) tokens"
                        : self.localization.localized(.statusItemAccessibility)
                }
            }
        }
    }

    public func forceSync() {
        Task {
            _ = try? await syncCoordinator.syncAll()
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
