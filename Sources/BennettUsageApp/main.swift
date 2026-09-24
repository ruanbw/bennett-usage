import AppKit
import BennettUsageCore

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

let statusController = StatusItemController(
    aggregator: aggregator,
    syncCoordinator: coordinator,
    openDashboardAction: {
        DashboardWindowManager.shared.show(aggregator: aggregator, syncCoordinator: coordinator)
    },
    openSettingsAction: {
        DashboardWindowManager.shared.show(aggregator: aggregator, syncCoordinator: coordinator, openSettings: true)
    }
)
if CommandLine.arguments.contains("--dashboard") || CommandLine.arguments.contains("-d") || CommandLine.arguments.contains("--open-dashboard") {
    DashboardWindowManager.shared.show(aggregator: aggregator, syncCoordinator: coordinator)
}

// Start watching and initial background sync
Task {
    await coordinator.startWatching()
    _ = try? await coordinator.syncAll()
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

app.run()
