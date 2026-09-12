import Foundation

public actor SyncCoordinator {
    private let database: DatabaseManager
    private let registry: AdapterRegistry
    private let pricingEngine: PricingEngine
    private var watcher: FSEventsWatcher?
    // Coalescing: while a sync is running, additional FSEvent-triggered
    // requests collapse into a single follow-up pass instead of queueing one
    // full-tree walk per event.
    private var isSyncing = false
    private var needsResync = false

    public init(
        database: DatabaseManager,
        registry: AdapterRegistry = .shared,
        pricingEngine: PricingEngine = .shared
    ) {
        self.database = database
        self.registry = registry
        self.pricingEngine = pricingEngine
    }

    @discardableResult
    public func syncAll(changedPaths: [String]? = nil) async throws -> Int {
        if isSyncing {
            needsResync = true
            return 0
        }
        isSyncing = true
        defer { isSyncing = false }
        var total = 0
        repeat {
            needsResync = false
            total += try await syncAllOnce(changedPaths: changedPaths)
        } while needsResync
        return total
    }

    private func syncAllOnce(changedPaths: [String]? = nil) async throws -> Int {
        var totalIngested = 0
        for adapter in registry.allAdapters() {
            guard let path = dataRoot(for: adapter) else { continue }
            // Event-driven sync: skip adapters whose watched tree contains
            // none of the changed paths — no new consumption there to read.
            if let changedPaths, !changedPaths.isEmpty,
               !Self.isPathAffected(root: path.path, changedPaths: changedPaths) {
                continue
            }
            do {
                let cursor = try database.fetchCursor(for: adapter.sourceId)
                let (records, newCursor) = try await Self.fetchOffActor(adapter, from: path, since: cursor)

                let isCutover: Bool
                switch (cursor, newCursor) {
                case (.rowId, .fileOffsets):
                    isCutover = true
                case (.fileOffsets, .rowId):
                    isCutover = true
                default:
                    isCutover = false
                }

                let finalRecords: [UnifiedTokenRecord]
                let finalCursor: SyncCursor
                if isCutover {
                    try database.resetRecords(for: adapter.sourceId)
                    let (freshRecords, freshCursor) = try await Self.fetchOffActor(adapter, from: path, since: nil)
                    finalRecords = freshRecords
                    finalCursor = freshCursor
                } else {
                    finalRecords = records
                    finalCursor = newCursor
                }

                // Attach pricing if missing
                let pricedRecords = finalRecords.map { record -> UnifiedTokenRecord in
                    if record.rawCostUSD == nil || record.rawCostUSD == 0.0 {
                        let cost = pricingEngine.calculateCost(
                            model: record.model,
                            input: record.inputTokens,
                            output: record.outputTokens,
                            cacheRead: record.cacheReadTokens,
                            cacheWrite: record.cacheWriteTokens
                        )
                        return UnifiedTokenRecord(
                            id: record.id,
                            sourceId: record.sourceId,
                            timestamp: record.timestamp,
                            dayKey: record.dayKey,
                            sessionKey: record.sessionKey,
                            projectFolder: record.projectFolder,
                            model: record.model,
                            provider: record.provider,
                            inputTokens: record.inputTokens,
                            outputTokens: record.outputTokens,
                            cacheReadTokens: record.cacheReadTokens,
                            cacheWriteTokens: record.cacheWriteTokens,
                            rawCostUSD: cost
                        )
                    }
                    return record
                }

                // No new records and an unchanged cursor: nothing to persist.
                if !pricedRecords.isEmpty || finalCursor != cursor {
                    try database.insertRecords(pricedRecords, updateCursorFor: adapter.sourceId, cursor: finalCursor)
                }
                totalIngested += pricedRecords.count
            } catch {
                print("Error syncing adapter \(adapter.sourceId): \(error)")
            }
        }
        if totalIngested > 0 {
            let count = totalIngested
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .bennettUsageDataDidUpdate,
                    object: nil,
                    userInfo: ["ingested": count]
                )
            }
        }
        return totalIngested
    }

    /// True when a changed path lies inside the adapter's watched root (or is
    /// the root itself, or a parent of it — FSEvents may coalesce upward).
    private static func isPathAffected(root: String, changedPaths: [String]) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        for changed in changedPaths {
            let normalized = changed.hasSuffix("/") ? String(changed.dropLast()) : changed
            if normalized == normalizedRoot
                || normalized.hasPrefix(normalizedRoot + "/")
                || normalizedRoot.hasPrefix(normalized + "/") {
                return true
            }
        }
        return false
    }

    public func startWatching() {
        let paths = registry.allAdapters().compactMap { dataRoot(for: $0)?.path }
        self.watcher = FSEventsWatcher(paths: paths) { [weak self] eventPaths in
            Task { [weak self] in
                _ = try? await self?.syncAll(changedPaths: eventPaths)
            }
        }
    }

    /// Adapter fetches do full-tree enumeration + JSON parsing synchronously.
    /// Running them inside the actor stalled the cooperative pool for tens of
    /// seconds on first launch and queued UI refreshes; run the heavy section
    /// on a detached task and let the actor await only the result. Cursors and
    /// persistence stay on the actor.
    private nonisolated static func fetchOffActor(
        _ adapter: AgentSourceAdapter,
        from path: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await Task.detached(priority: .userInitiated) {
            try await adapter.fetchIncrementalRecords(from: path, since: cursor)
        }.value
    }

    /// Directory the coordinator watches and enumerates for an adapter.
    /// - `isSyncStub` adapters (no fetch implementation) are skipped outright.
    /// - Otherwise the narrowed `syncRootPath` is used when it exists as a
    ///   directory (e.g. gemini → ~/.gemini/tmp).
    /// - Otherwise the adapter's own detection applies (preserves OmpAdapter's
    ///   stats.db fallback when the sessions directory is missing). Custom
    ///   adapters without narrowing knowledge are unaffected.
    private func dataRoot(for adapter: AgentSourceAdapter) -> URL? {
        if adapter.isSyncStub { return nil }
        if let raw = adapter.syncRootPath, !raw.isEmpty {
            let narrowed = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: narrowed.path, isDirectory: &isDir), isDir.boolValue {
                return narrowed
            }
        }
        return adapter.detectDefaultPath()
    }
}
