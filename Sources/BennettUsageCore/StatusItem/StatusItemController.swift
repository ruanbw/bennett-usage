import AppKit
import Combine
import SwiftUI

@MainActor
public final class StatusItemController: NSObject {
    /// The last values pushed to the status item.
    ///
    /// `NSStatusItem` is rendered out of process by Control Center, so writing
    /// identical values again still costs a scene update and a re-render. Every
    /// write is diffed against this snapshot first.
    struct StatusItemRender: Equatable {
        var title: String
        var symbolName: String
        var imageDescription: String
        var tooltip: String
        var accessibilityLabel: String
        var accessibilityHelp: String
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    // Only touched on the main actor (setup + deinit); `nonisolated(unsafe)`
    // keeps it reachable from the nonisolated `deinit` that removes it.
    nonisolated(unsafe) private var outsideClickMonitor: Any?
    private let aggregator: MetricsAggregator
    private let syncCoordinator: SyncCoordinator
    private let summaryModel = StatusSummaryModel()
    private let updateChecker: UpdateChecker
    /// The last fully successful source sync shown in the status item.
    /// Kept internal so tests can verify that normal partial-failure returns do
    /// not fabricate a successful timestamp.
    private(set) var lastSyncDate: Date?
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void
    private let localization: LocalizationManager
    private var refreshTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var updateObservation: AnyCancellable?
    private var localizationObservation: AnyCancellable?
    private var syncStatusObservation: AnyCancellable?
    /// Block-based observers. Selector-based observers delivered Foundation's
    /// `.NSCalendarDayChanged` on a background queue, and invoking an `@MainActor`
    /// `@objc` method from there tripped Swift's executor assertion and killed the
    /// process at every midnight rollover.
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    private var tooltipRefreshTask: Task<Void, Never>?
    private var lastRenderedStatusItem: StatusItemRender?
    /// Actual status-item writes. Internal so tests can prove that repeated
    /// refreshes with unchanged content do not touch the remote view.
    private(set) var statusItemWriteCount = 0

    public init(
        aggregator: MetricsAggregator,
        syncCoordinator: SyncCoordinator,
        localization: LocalizationManager = .shared,
        updateChecker: UpdateChecker = .shared,
        heartbeatInterval: TimeInterval? = 60.0,
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
        // Delivered on the main queue: `.NSCalendarDayChanged` and the workspace
        // wake notification are posted from background queues.
        let notificationCenter = NotificationCenter.default
        notificationObservers.append(
            notificationCenter.addObserver(forName: .bennettUsageDataDidUpdate, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshData() }
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshData() }
            }
        )
        notificationObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleSystemDidWake() }
            }
        )
        // A background check can land long after launch; the menu bar icon is
        // the only surface a popover-shy user ever looks at.
        updateObservation = Publishers.CombineLatest(
            updateChecker.$status,
            updateChecker.$skippedVersion
        )
        .sink { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyStatusItemAppearance() }
        }
        localizationObservation = localization.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyStatusItemAppearance()
                }
            }
        syncStatusObservation = NotificationCenter.default.publisher(for: .bennettUsageSyncStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateDisplayedSyncStatus()
                }
            }
        Task { @MainActor [weak self] in
            await self?.updateDisplayedSyncStatus()
        }
        refreshData()

        if let heartbeatInterval, heartbeatInterval > 0 {
            heartbeatTask = Task { [weak self, syncCoordinator] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    // Safety net only: FSEvents drives the steady state, so this
                    // avoids re-enumerating every source tree on each tick.
                    _ = try? await syncCoordinator.syncHeartbeat()
                    guard !Task.isCancelled, let self else { break }
                    self.recordSuccessfulSync()
                    self.refreshData()
                }
            }
        }

        // The tooltip embeds a relative "synced N minutes ago" time, the one piece
        // of status-item content that changes while nothing else does. Refresh it
        // on a slow tick instead of recomputing it per sync notification; the diff
        // in `applyStatusItemAppearance` keeps each tick write-free until the
        // rendered minute actually rolls over.
        tooltipRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.applyStatusItemAppearance()
            }
        }
    }

    deinit {
        heartbeatTask?.cancel()
        tooltipRefreshTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    private func handleSystemDidWake() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.syncCoordinator.syncForUI(force: true)
                self.recordSuccessfulSync()
            } catch {
                // A wake is a retry opportunity, not proof of a successful sync.
            }
            self.refreshData()
        }
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let accessibilityLabel = localization.localized(.statusItemAccessibility)
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: accessibilityLabel)
            button.setAccessibilityLabel(accessibilityLabel)
            button.setAccessibilityRole(.button)
            button.setAccessibilityHelp(localization.localized(.openDashboardShortcut))
            button.toolTip = accessibilityLabel
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
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }
        popover.contentSize = fittingSize
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        sizePopoverToContent()
        // Show immediately with the cached summary; refresh runs async.
        // Opening the popover is frequent and must not run a full-tree sync
        // every click (U-01), so this path uses the throttled UI sync. The
        // refresh below runs unconditionally after it, so a throttled pass
        // still re-reads (a concurrent FSEvents sync may have inserted).
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A status-item popover can be shown while the accessory app is still
        // inactive. Explicitly activate and key its panel so SwiftUI controls
        // receive keyboard focus on the first click, not only after a second
        // click elsewhere in the app.
        NSApp.activate(ignoringOtherApps: true)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.makeKey()
            popoverWindow.makeFirstResponder(popover.contentViewController?.view)
        }
        refreshData()
        Task {
            do {
                _ = try await syncCoordinator.syncForUI()
                recordSuccessfulSync()
            } catch {
                // Keep the previous last-sync time when a sync attempt fails;
                // the cached summary remains useful while the watcher retries.
            }
            // `syncForUI` is throttled and only posts a notification when
            // it actually inserts rows; always re-read afterwards so a
            // throttled pass (or a concurrent FSEvents sync) still leaves the
            // popover showing fresh data instead of the stale cache.
            refreshData()
        }
    }

    public func refreshData() {
        // Latest-wins: overlapping notifications used to race and a slow
        // earlier fetch could overwrite a fresher summary. Cancel the
        // in-flight read so only the newest request publishes.
        refreshTask?.cancel()
        let aggregator = self.aggregator
        // The sparkline only exists inside the popover. Reading it while the
        // popover is closed aggregated the whole day for a view nobody can see.
        let needsTrend = popover.isShown
        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (TodaySummary, [TrendPoint]?, Int?)? in
                let summary: TodaySummary?
                if let res = try? await aggregator.fetchTodaySummary() {
                    summary = res
                } else {
                    // Retry once after a brief yield in case the database was
                    // locked during a transaction.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    summary = try? await aggregator.fetchTodaySummary()
                }
                guard let summary else { return nil }

                // Yesterday, for the popover's period-over-period line. It is
                // read on the same pass as today so the two numbers cannot come
                // from different snapshots, and a failure here degrades to "no
                // comparison" rather than to a wrong delta.
                let comparison = try? await aggregator.fetchComparisonPeriod(
                    range: .today,
                    toolFilter: nil
                )
                let yesterdayTotal = comparison?.totalTokens

                // The sparkline is optional presentation data. A failed trend
                // read must not erase a valid Today summary or fabricate a
                // flat line; the popover simply keeps its previous trend.
                guard needsTrend else { return (summary, nil, yesterdayTotal) }
                let trend = (try? await aggregator.fetchPeriodMetrics(
                    range: .today,
                    toolFilter: nil
                ))?.trendPoints ?? []
                return (summary, trend, yesterdayTotal)
            }.value

            guard !Task.isCancelled, let (summary, trend, yesterdayTotal) = result else {
                // A read that failed twice leaves the previous snapshot on
                // screen. Saying so is the only honest option: the numbers may
                // be minutes or days old, and the sync freshness above them
                // describes a different thing (source parsing, not the local
                // read that feeds this popover).
                if !Task.isCancelled, !summaryModel.dataReadFailed {
                    summaryModel.dataReadFailed = true
                    applyStatusItemAppearance()
                }
                return
            }
            // Published properties invalidate the observing SwiftUI view tree, so
            // only real changes are written.
            if summaryModel.dataReadFailed {
                summaryModel.dataReadFailed = false
            }
            if summaryModel.summary != summary {
                summaryModel.summary = summary
            }
            if let trend {
                summaryModel.trendPoints = trend.count >= 2 ? trend : nil
            }
            if summaryModel.yesterdayTotal != yesterdayTotal {
                summaryModel.yesterdayTotal = yesterdayTotal
            }
            // This timestamp describes a database read only. Source-sync
            // freshness is published separately from SyncCoordinator status.
            summaryModel.lastRefreshedAt = Date()
            applyStatusItemAppearance()
        }
    }

    /// Renders the status item from the current summary + update state. Called
    /// both when data lands and when the update checker changes, so the two
    /// sources never overwrite each other's contribution to the icon/tooltip.
    ///
    /// Every write is diffed against the previous render first: `NSStatusItem` is
    /// drawn out of process by Control Center, so assigning an identical title
    /// still costs a cross-process scene update plus a re-render.
    func applyStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let accessibilityLabel = localization.localized(.statusItemAccessibility)
        let tokens = summaryModel.summary?.totalTokens ?? 0
        let tokenTitle = TokenFormatter.formatStatusTitle(tokens)

        var tooltip = tokens > 0
            ? String(format: localization.localized(.tokenValue), TokenFormatter.formatFull(tokens))
            : accessibilityLabel
        // A failed local read is worth stating in the tooltip: the number above
        // it is the last one that could be read, not the current total.
        if summaryModel.dataReadFailed {
            tooltip += " · " + localization.localized(.staleData)
        }
        if let syncText = lastSyncText() {
            tooltip += " · " + syncText
        }

        let symbolName: String
        let imageDescription: String
        if let update = updateChecker.availableUpdate {
            let updateText = String(
                format: localization.localized(.updateAvailableTitle),
                update.version.description
            )
            symbolName = "arrow.down.circle"
            imageDescription = updateText
            tooltip += " · " + updateText
        } else {
            symbolName = "sparkles"
            imageDescription = accessibilityLabel
        }

        let render = StatusItemRender(
            title: tokenTitle,
            symbolName: symbolName,
            imageDescription: imageDescription,
            tooltip: tooltip,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: localization.localized(.openDashboardShortcut)
        )
        guard render != lastRenderedStatusItem else { return }
        lastRenderedStatusItem = render
        statusItemWriteCount += 1

        button.setAccessibilityLabel(render.accessibilityLabel)
        button.setAccessibilityHelp(render.accessibilityHelp)
        button.title = render.title
        button.image = NSImage(
            systemSymbolName: render.symbolName,
            accessibilityDescription: render.imageDescription
        )
        button.toolTip = render.tooltip
        button.setAccessibilityValue(render.tooltip)
    }

    private func lastSyncText() -> String? {
        guard let lastSyncDate else { return nil }
        let elapsed = max(0, Date().timeIntervalSince(lastSyncDate))
        if elapsed < 60 {
            return localization.localized(.syncedJustNow)
        }
        let minutes = max(1, Int(elapsed / 60))
        return localization.localized(.syncedMinutesAgo, arguments: minutes)
    }

    /// Re-reads the coordinator's completed status before recording a sync.
    /// The synchronous API remains source-compatible for existing callers, but
    /// a normal return from a partially failed sync no longer implies success.
    public func recordSuccessfulSync() {
        Task { [weak self] in
            await self?.updateDisplayedSyncStatus()
        }
    }

    func updateDisplayedSyncStatus() async {
        let status = await syncCoordinator.currentSyncStatus()
        let lastSuccessful = status.lastSuccessfulAt.map {
            LastSuccessfulRefresh(completedAt: $0)
        }
        let partialFailure = status.failures.isEmpty ? nil : "source_sync_failed"

        let freshness = SyncFreshnessModel(
            lastChecked: status.lastAttemptAt,
            lastSuccessful: lastSuccessful,
            isRefreshing: status.phase == .syncing,
            partialFailure: partialFailure
        )
        // Only publish a real change: every assignment invalidates the SwiftUI
        // view tree that observes this model.
        if summaryModel.freshness != freshness {
            summaryModel.freshness = freshness
        }

        // Keep the status item timestamp tied to a real successful source sync.
        // A partial failure may retain the previous successful date in the model,
        // but it must not create a new success timestamp.
        if status.phase == .idle,
           status.failures.isEmpty,
           let lastSuccessfulAt = status.lastSuccessfulAt {
            lastSyncDate = lastSuccessfulAt
        }
        applyStatusItemAppearance()
    }

    /// Explicit user-initiated sync (the popover’s “Sync Now” button).
    /// `force: true` bypasses the UI throttle so a deliberate refresh is never
    /// swallowed, then the summary is refreshed.
    public func forceSync() {
        Task {
            do {
                _ = try await syncCoordinator.syncForUI(force: true)
                recordSuccessfulSync()
            } catch {
                // A failed explicit sync should not claim a successful timestamp.
            }
            refreshData()
        }
    }

    /// Dismisses the popover without changing the app's current surface.
    /// Keyboard commands use this before opening a standalone window so a
    /// status-panel click cannot leave two app-owned surfaces stacked.
    public func dismissPopover() {
        popover.performClose(nil)
    }

    private func openDashboardWindow() {
        dismissPopover()
        openDashboardAction()
    }

    private func openSettings() {
        popover.performClose(nil)
        openSettingsAction()
    }
}
