import AppKit
import BennettUsageCore

/// Retained command target for the accessory app's local application menu.
///
/// These are ordinary AppKit key equivalents: they work when this app is
/// active and never install a system-wide/global shortcut. Keeping the target
/// in a top-level strong binding is important because `NSMenuItem.target` is
/// not a reliable ownership boundary.
@MainActor
final class AppCommandController: NSObject {
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void
    private let syncNowAction: () -> Void
    private let quitAction: () -> Void

    init(
        openDashboardAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void,
        syncNowAction: @escaping () -> Void,
        quitAction: @escaping () -> Void
    ) {
        self.openDashboardAction = openDashboardAction
        self.openSettingsAction = openSettingsAction
        self.syncNowAction = syncNowAction
        self.quitAction = quitAction
        super.init()
    }

    @objc func showDashboard(_ sender: Any?) {
        openDashboardAction()
    }

    @objc func showSettings(_ sender: Any?) {
        openSettingsAction()
    }

    @objc func syncNow(_ sender: Any?) {
        syncNowAction()
    }

    @objc func quit(_ sender: Any?) {
        quitAction()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbDir = appSupport.appendingPathComponent("BennettUsage")
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("usage.db").path

guard let db = try? DatabaseManager(path: dbPath) else {
    fatalError("Failed to initialize usage database")
}

// Register default adapters in catalog order.
for adapter in AdapterCatalog.defaults {
    AdapterRegistry.shared.register(adapter)
}

let aggregator = MetricsAggregator(database: db)
let coordinator = SyncCoordinator(database: db)

// Keep all shell actions on the same callbacks used by the status-item popover.
// In particular, Settings is a separate window and must not mutate/close the
// Dashboard window's presentation state.
let openDashboardAction: () -> Void = {
    DashboardWindowManager.shared.show(aggregator: aggregator, syncCoordinator: coordinator)
}
let openSettingsAction: () -> Void = {
    SettingsWindowManager.shared.show(aggregator: aggregator)
}

let statusController = StatusItemController(
    aggregator: aggregator,
    syncCoordinator: coordinator,
    openDashboardAction: openDashboardAction,
    openSettingsAction: openSettingsAction
)

let commandTarget = AppCommandController(
    openDashboardAction: {
        statusController.dismissPopover()
        openDashboardAction()
    },
    openSettingsAction: {
        statusController.dismissPopover()
        openSettingsAction()
    },
    syncNowAction: {
        statusController.dismissPopover()
        statusController.forceSync()
    },
    quitAction: { NSApp.terminate(nil) }
)

// A small local main menu gives the app reliable ⌘D / ⌘, / ⌘Q commands while
// preserving `.accessory` behavior. No global event tap or shortcut
// registration is used, so these commands cannot intercept another app.
let mainMenu = NSMenu()
let applicationMenuItem = NSMenuItem()
mainMenu.addItem(applicationMenuItem)
let applicationMenu = NSMenu(title: "Bennett Usage")
applicationMenuItem.submenu = applicationMenu

let dashboardMenuItem = NSMenuItem(
    title: LocalizationManager.shared.localized(.navDashboard),
    action: #selector(AppCommandController.showDashboard(_:)),
    keyEquivalent: "d"
)
dashboardMenuItem.keyEquivalentModifierMask = [.command]
dashboardMenuItem.target = commandTarget
applicationMenu.addItem(dashboardMenuItem)

let settingsMenuItem = NSMenuItem(
    title: LocalizationManager.shared.localized(.navSettings),
    action: #selector(AppCommandController.showSettings(_:)),
    keyEquivalent: ","
)
settingsMenuItem.keyEquivalentModifierMask = [.command]
settingsMenuItem.target = commandTarget
applicationMenu.addItem(settingsMenuItem)

let syncMenuItem = NSMenuItem(
    title: LocalizationManager.shared.localized(.syncNow),
    action: #selector(AppCommandController.syncNow(_:)),
    keyEquivalent: "r"
)
syncMenuItem.keyEquivalentModifierMask = [.command]
syncMenuItem.target = commandTarget
applicationMenu.addItem(syncMenuItem)

applicationMenu.addItem(.separator())
let quitMenuItem = NSMenuItem(
    title: LocalizationManager.shared.localized(.quit),
    action: #selector(AppCommandController.quit(_:)),
    keyEquivalent: "q"
)
quitMenuItem.keyEquivalentModifierMask = [.command]
quitMenuItem.target = commandTarget
applicationMenu.addItem(quitMenuItem)
app.mainMenu = mainMenu

let arguments = CommandLine.arguments
let shouldOpenDashboard = arguments.contains("--dashboard")
    || arguments.contains("-d")
    || arguments.contains("--open-dashboard")
let shouldOpenSettings = arguments.contains("--settings")
    || arguments.contains("--open-settings")

if shouldOpenSettings {
    openSettingsAction()
} else if shouldOpenDashboard {
    openDashboardAction()
}

// Start watching and initial background sync. Only the coordinator's awaited
// completion updates the status-item sync timestamp; a later presentation
// refresh is not evidence that a sync actually ran.
Task {
    await coordinator.startWatching()
    do {
        _ = try await coordinator.syncAll()
        statusController.recordSuccessfulSync()
    } catch {
        // The watcher/heartbeat will retry; leave the last-sync timestamp at
        // its previous truthful value.
    }
    statusController.refreshData()
}

// Update check. The launch check is throttled internally to once a day, so the
// timer only has to be frequent enough to catch a menu bar session that stays
// open for weeks (and to survive sleep/wake drift).
Task {
    await UpdateChecker.shared.checkAutomatically()
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6 * 60 * 60))
        guard !Task.isCancelled else { break }
        await UpdateChecker.shared.checkAutomatically()
    }
}

// `commandTarget` is intentionally a top-level strong binding. It owns the
// menu targets for the entire accessory-app lifetime.
withExtendedLifetime(commandTarget) {
    app.run()
}
