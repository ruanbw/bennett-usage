import AppKit
import BennettUsageCore
import Combine

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

    /// ⌘1–⌘5. Each item carries its own zero-based index, so adding or
    /// reordering a range is a menu edit rather than a change to the keyboard
    /// handling.
    @objc func selectRange(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let index = item.tag as? Int else { return }
        NotificationCenter.default.post(
            name: .bennettUsageRangeShortcut,
            object: nil,
            userInfo: ["index": index]
        )
    }

    @objc func quit(_ sender: Any?) {
        quitAction()
    }
}

let app = NSApplication.shared
let storedThemeMode = UserDefaults.standard.string(forKey: AppThemeMode.storageKey)
let themeMode = storedThemeMode.flatMap(AppThemeMode.init(rawValue:)) ?? .dark
app.appearance = themeMode.appearance
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

// ⌘1–⌘5 select the dashboard's time range. Registered as ordinary menu key
// equivalents rather than as an event tap: the app stays an accessory, cannot
// intercept another application, and gets the system's own menu priority for
// free.
let rangeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
let rangeSubmenu = NSMenu(title: "Range")
let rangeTitles: [(Int, String, String)] = [
    (1, "24h", "range24h"),
    (2, "Today", "rangeToday"),
    (3, "7 Days", "range7Days"),
    (4, "30 Days", "range30Days"),
    (5, "1 Year", "range1Year")
]
var rangeMenuItems: [NSMenuItem] = []
for (index, fallbackTitle, keyName) in rangeTitles {
    let item = NSMenuItem(
        title: fallbackTitle,
        action: #selector(AppCommandController.selectRange(_:)),
        keyEquivalent: String(index)
    )
    item.keyEquivalentModifierMask = [.command]
    item.target = commandTarget
    item.tag = index - 1
    rangeSubmenu.addItem(item)
    rangeMenuItems.append(item)
}
rangeMenuItem.submenu = rangeSubmenu
applicationMenu.addItem(rangeMenuItem)

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

let localizationObservation = LocalizationManager.shared.objectWillChange
    .sink { _ in
        Task { @MainActor in
            let localization = LocalizationManager.shared
            dashboardMenuItem.title = localization.localized(.navDashboard)
            settingsMenuItem.title = localization.localized(.navSettings)
            syncMenuItem.title = localization.localized(.syncNow)
            quitMenuItem.title = localization.localized(.quit)
            for (item, entry) in zip(rangeMenuItems, rangeTitles) {
                switch entry.2 {
                case "range24h": item.title = localization.localized(.range24h)
                case "rangeToday": item.title = localization.localized(.rangeToday)
                case "range7Days": item.title = localization.localized(.range7Days)
                case "range30Days": item.title = localization.localized(.range30Days)
                default: item.title = localization.localized(.range1Year)
                }
            }
            DashboardWindowManager.shared.updateLocalizedTitle(localization: localization)
            SettingsWindowManager.shared.updateLocalizedTitle(localization: localization)
        }
    }

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

// A status-item app is normally quit through `NSApp.terminate`, which exits the
// process without closing SQLite, so the write-ahead log is reclaimed explicitly.
let terminationObservation = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    db.checkpointAndTruncate()
}

// `commandTarget` is intentionally a top-level strong binding. It owns the
// menu targets for the entire accessory-app lifetime.
withExtendedLifetime((commandTarget, localizationObservation, terminationObservation)) {
    app.run()
}
